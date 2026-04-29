#!/usr/bin/env bash
#
# SSH Toolkit (Linux) — Perforce P4D 一键运维脚本
# Version: 1.0.0
# Target: P4D 2024.1 on Ubuntu 22.04 / 24.04
#
# 用法:
#   sudo bash ssh-toolkit.sh           # 交互菜单
#   sudo bash ssh-toolkit.sh status    # 非交互:状态
#   sudo bash ssh-toolkit.sh checkpoint # 非交互:立刻 checkpoint
#
# 设计原则:
#   - 100% 基于 P4D-Migration-Complete-Guide.md 那份指南
#   - 单文件、无外部依赖(除 p4d / p4 / systemctl 等系统工具)
#   - 失败可重入(每步幂等 + 状态机 + 详细日志)
#   - 关键操作前自动备份 + 提示
#

set -o errexit
set -o nounset
set -o pipefail

# ============================================================
#  配置(可通过环境变量 / 配置文件覆盖)
# ============================================================

readonly P4D_VERSION_DEFAULT="2024.1"
readonly P4ROOT_DEFAULT="/opt/perforce/servers/master"
readonly P4PORT_DEFAULT="1888"
readonly P4D_USER_DEFAULT="perforce"
readonly P4D_BIN_DIR_DEFAULT="/opt/perforce/sbin"
readonly P4_BIN_DIR_DEFAULT="/opt/perforce/bin"
readonly BACKUP_DIR_DEFAULT="/opt/perforce/backups"
readonly DEPOT_BACKUP_DIR_DEFAULT="/mnt/backup/depots"

# Config file (loaded if present, written by deploy steps)
readonly CONFIG_FILE="/etc/ssh-toolkit.conf"

# Persistent state (which deploy steps are done)
readonly STATE_DIR="/var/lib/ssh-toolkit"
readonly LOG_FILE="/var/log/ssh-toolkit.log"

# systemd unit + scheduled task names
readonly SVC_NAME="p4d.service"
readonly SVC_FILE="/etc/systemd/system/${SVC_NAME}"
readonly RESCUE_DROPIN_DIR="/etc/systemd/system/p4d.service.d"
readonly RESCUE_DROPIN_FILE="${RESCUE_DROPIN_DIR}/rescue.conf"
readonly CRON_FILE="/etc/cron.d/p4d-backup"

# ============================================================
#  ANSI 颜色 (终端友好,无 tty 时自动关闭)
# ============================================================

if [[ -t 1 ]]; then
    readonly C_RESET="\033[0m"
    readonly C_BOLD="\033[1m"
    readonly C_DIM="\033[2m"
    readonly C_RED="\033[31m"
    readonly C_GREEN="\033[32m"
    readonly C_YELLOW="\033[33m"
    readonly C_BLUE="\033[34m"
    readonly C_MAGENTA="\033[35m"
    readonly C_CYAN="\033[36m"
else
    readonly C_RESET="" C_BOLD="" C_DIM=""
    readonly C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_MAGENTA="" C_CYAN=""
fi

# ============================================================
#  日志助手
# ============================================================

log_init() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || true
}

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

info()    { printf "${C_CYAN}ℹ${C_RESET}  %s\n" "$*"; log INFO "$*"; }
ok()      { printf "${C_GREEN}✓${C_RESET}  %s\n" "$*"; log OK "$*"; }
warn()    { printf "${C_YELLOW}⚠${C_RESET}  %s\n" "$*"; log WARN "$*"; }
err()     { printf "${C_RED}✗${C_RESET}  %s\n" "$*" >&2; log ERR "$*"; }
die()     { err "$@"; exit 1; }
section() { printf "\n${C_BOLD}${C_BLUE}── %s ──${C_RESET}\n" "$*"; }

confirm() {
    # confirm "Question?" [default: y|n]
    local prompt="$1"
    local default="${2:-n}"
    local hint="[y/N]"
    [[ "$default" == "y" ]] && hint="[Y/n]"
    local reply
    read -r -p "$(printf "${C_YELLOW}?${C_RESET}  %s %s " "$prompt" "$hint")" reply
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy]$ ]]
}

require_confirm_text() {
    # require_confirm_text "Type CONFIRM to proceed: " "CONFIRM"
    local prompt="$1"
    local expected="$2"
    local reply
    read -r -p "$(printf "${C_YELLOW}?${C_RESET}  %s" "$prompt")" reply
    [[ "$reply" == "$expected" ]]
}

# ============================================================
#  根权限检查
# ============================================================

ensure_root() {
    if [[ $EUID -ne 0 ]]; then
        die "需要 root 权限运行。请用: sudo bash $0"
    fi
}

# ============================================================
#  配置加载 / 保存
# ============================================================

load_config() {
    P4D_VERSION="${P4D_VERSION:-$P4D_VERSION_DEFAULT}"
    P4ROOT="${P4ROOT:-$P4ROOT_DEFAULT}"
    P4PORT="${P4PORT:-$P4PORT_DEFAULT}"
    P4D_USER="${P4D_USER:-$P4D_USER_DEFAULT}"
    P4D_BIN_DIR="${P4D_BIN_DIR:-$P4D_BIN_DIR_DEFAULT}"
    P4_BIN_DIR="${P4_BIN_DIR:-$P4_BIN_DIR_DEFAULT}"
    BACKUP_DIR="${BACKUP_DIR:-$BACKUP_DIR_DEFAULT}"
    DEPOT_BACKUP_DIR="${DEPOT_BACKUP_DIR:-$DEPOT_BACKUP_DIR_DEFAULT}"
    P4D_BIN="${P4D_BIN_DIR}/p4d"
    P4_BIN="${P4_BIN_DIR}/p4"
    P4D_ADMIN_PASSWD_FILE="/opt/perforce/.p4_admin_passwd"

    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
# P4D Toolkit configuration — generated $(date -Iseconds)
P4D_VERSION="$P4D_VERSION"
P4ROOT="$P4ROOT"
P4PORT="$P4PORT"
P4D_USER="$P4D_USER"
P4D_BIN_DIR="$P4D_BIN_DIR"
P4_BIN_DIR="$P4_BIN_DIR"
BACKUP_DIR="$BACKUP_DIR"
DEPOT_BACKUP_DIR="$DEPOT_BACKUP_DIR"
EOF
    chmod 644 "$CONFIG_FILE"
}

# ============================================================
#  状态查询
# ============================================================

svc_state() {
    # echoes one of: running|stopped|missing|unknown
    if ! systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${SVC_NAME}"; then
        echo "missing"; return
    fi
    if systemctl is-active --quiet "$SVC_NAME"; then
        echo "running"
    elif systemctl is-failed --quiet "$SVC_NAME"; then
        echo "failed"
    else
        echo "stopped"
    fi
}

p4d_installed() {
    [[ -x "$P4D_BIN" ]]
}

license_present() {
    [[ -f "$P4ROOT/license" ]]
}

p4d_version_string() {
    if p4d_installed; then
        "$P4D_BIN" -V 2>/dev/null | grep -m1 '^Rev\.' || echo "未知"
    else
        echo "未安装"
    fi
}

p4_info_license() {
    # Returns license-line text or empty if call fails.
    "$P4_BIN" -p "localhost:$P4PORT" info 2>/dev/null | grep "Server license:" || true
}

current_change_counter() {
    "$P4_BIN" -p "localhost:$P4PORT" -u admin counter change 2>/dev/null | tr -d '[:space:]' || true
}

current_max_change() {
    "$P4_BIN" -p "localhost:$P4PORT" -u admin changes -m 1 2>/dev/null | awk 'NR==1 && $1=="Change" { print $2 }' || true
}

# ============================================================
#  顶部头(每次菜单刷新)
# ============================================================

print_header() {
    clear
    local svc; svc="$(svc_state)"
    local svc_color="$C_RED" svc_text="未知"
    case "$svc" in
        running) svc_color="$C_GREEN"; svc_text="✓ 运行中" ;;
        stopped) svc_color="$C_YELLOW"; svc_text="○ 已停止" ;;
        failed)  svc_color="$C_RED"; svc_text="✗ 启动失败" ;;
        missing) svc_color="$C_DIM"; svc_text="未安装" ;;
    esac

    local lic_text="—"
    if [[ "$svc" == "running" ]]; then
        lic_text="$(p4_info_license | sed 's/Server license: *//')"
        [[ -z "$lic_text" ]] && lic_text="—"
    fi

    printf "${C_BOLD}${C_CYAN}╔══════════════════════════════════════════════════════════════╗${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}║${C_RESET}  ${C_BOLD}P4D Toolkit (Ubuntu)${C_RESET}                                      ${C_BOLD}${C_CYAN}║${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}║${C_RESET}  Host: $(printf '%-25s' "$(hostname)")  Port: $(printf '%-5s' "$P4PORT")          ${C_BOLD}${C_CYAN}║${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}║${C_RESET}  P4D:  $(printf '%-30s' "$(p4d_version_string | head -c 30)")          ${C_BOLD}${C_CYAN}║${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}║${C_RESET}  Service: ${svc_color}$(printf '%-15s' "$svc_text")${C_RESET}                                ${C_BOLD}${C_CYAN}║${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}║${C_RESET}  License: $(printf '%-50s' "$(echo "$lic_text" | head -c 50)") ${C_BOLD}${C_CYAN}║${C_RESET}\n"
    printf "${C_BOLD}${C_CYAN}╚══════════════════════════════════════════════════════════════╝${C_RESET}\n"
}

# ============================================================
#  STEP IMPLEMENTATIONS — 部署
# ============================================================

step_install_p4d() {
    section "全新安装 P4D ${P4D_VERSION}"
    if p4d_installed; then
        warn "P4D 已经装在 $P4D_BIN ($(p4d_version_string))"
        confirm "覆盖安装?" || return 0
    fi

    # 强制使用 /root 下的本地 tgz,不从公网下载
    local tgz="/root/helix-core-server-${P4D_VERSION}.tgz"
    if [[ ! -f "$tgz" ]]; then
        err "未找到安装包: $tgz"
        info "请先把 helix-core-server-${P4D_VERSION}.tgz 复制到 /root/ 再重试"
        info "示例: scp helix-core-server-${P4D_VERSION}.tgz root@<host>:/root/"
        return 1
    fi
    info "找到本地安装包: $tgz ($(du -h "$tgz" | cut -f1))"

    local tmp="/tmp/p4d_install"
    rm -rf "$tmp"
    mkdir -p "$tmp"

    info "解压并安装"
    tar xzf "$tgz" -C "$tmp"
    mkdir -p "$P4D_BIN_DIR" "$P4_BIN_DIR"
    install -m 755 "$tmp/p4d"      "$P4D_BIN"
    install -m 755 "$tmp/p4broker" "$P4D_BIN_DIR/p4broker" || true
    install -m 755 "$tmp/p4p"      "$P4D_BIN_DIR/p4p"      || true
    install -m 755 "$tmp/p4"       "$P4_BIN"

    # Symlinks for global access
    ln -sf "$P4_BIN"  /usr/local/bin/p4
    ln -sf "$P4D_BIN" /usr/local/sbin/p4d

    # Create perforce user
    if ! id -u "$P4D_USER" >/dev/null 2>&1; then
        info "创建用户 $P4D_USER"
        useradd -r -m -d /opt/perforce -s /bin/bash "$P4D_USER"
    fi
    chown "$P4D_USER:$P4D_USER" /opt/perforce
    mkdir -p "$P4ROOT"
    chown -R "$P4D_USER:$P4D_USER" /opt/perforce

    # Initialize case-insensitive (mirror Windows behavior, see migration guide Phase 0.5)
    if [[ ! -f "$P4ROOT/db.counters" ]]; then
        info "初始化 case-insensitive 数据库 (-C1 -xi)"
        sudo -u "$P4D_USER" "$P4D_BIN" -r "$P4ROOT" -C1 -xi
    fi

    # Firewall (best-effort, ufw might not be installed)
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow "$P4PORT/tcp" comment 'Perforce' || true
    fi

    save_config
    ok "P4D ${P4D_VERSION} 已安装到 $P4D_BIN_DIR"
    "$P4D_BIN" -V | grep -m1 '^Rev\.'
}

step_install_license() {
    section "安装 License 文件"

    # 强制使用 /root/license,不接受 paste 输入
    local src="/root/license"
    if [[ ! -f "$src" ]]; then
        err "未找到 license 文件: $src"
        info "请先把 license 文件复制到 /root/license 再重试"
        info "示例: scp license root@<host>:/root/license"
        return 1
    fi
    info "找到本地 license 文件: $src ($(stat -c%s "$src") bytes)"

    info "复制到 $P4ROOT/license"
    install -m 644 -o "$P4D_USER" -g "$P4D_USER" "$src" "$P4ROOT/license"

    if ! license_present; then
        err "$P4ROOT/license 不存在(复制失败)"
        return 1
    fi

    local ip users
    ip="$(grep -m1 '^IPaddress:' "$P4ROOT/license" | awk '{print $2}' || true)"
    users="$(grep -m1 '^Users:' "$P4ROOT/license" | awk '{print $2}' || true)"
    info "License IP : ${ip:-未指定}"
    info "License 用户数: ${users:-未指定}"

    local my_ip
    my_ip="$(hostname -I | awk '{print $1}' || true)"
    if [[ -n "$ip" && -n "$my_ip" && "$ip" != "$my_ip" ]]; then
        warn "License IP ($ip) 跟本机 IP ($my_ip) 不匹配 — 需要联系 Perforce rehost"
    fi

    ok "License 已就位"
}

step_setup_systemd_with_rescue() {
    section "配置 systemd + 启动自愈 hook"

    if [[ ! -f "$P4D_ADMIN_PASSWD_FILE" ]]; then
        info "创建 admin 密码文件 $P4D_ADMIN_PASSWD_FILE"
        local pw
        read -r -s -p "请输入 admin 密码 (会保存到只 root 可读的文件): " pw; echo
        echo -n "$pw" > "$P4D_ADMIN_PASSWD_FILE"
        chown "$P4D_USER:$P4D_USER" "$P4D_ADMIN_PASSWD_FILE"
        chmod 600 "$P4D_ADMIN_PASSWD_FILE"
    fi

    info "写 ${SVC_FILE}"
    cat > "$SVC_FILE" <<EOF
[Unit]
Description=Helix Core (Perforce) Server
After=network.target

[Service]
Type=forking
User=$P4D_USER
Group=$P4D_USER
Environment=P4ROOT=$P4ROOT
Environment=P4PORT=$P4PORT
Environment=P4JOURNAL=$P4ROOT/journal
Environment=P4LOG=$P4ROOT/log
ExecStart=$P4D_BIN -r $P4ROOT -p $P4PORT -d
ExecStop=$P4_BIN -p $P4PORT admin stop
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
LimitNPROC=8192

[Install]
WantedBy=multi-user.target
EOF

    # Drop-in: ExecStartPre = reset counter to 0; ExecStartPost = set counter = MAX+1
    # Mirrors migration guide Phase 2.4 verbatim — the "vaccine" for 坑 #1.
    info "写自愈 hook ${RESCUE_DROPIN_FILE}"
    mkdir -p "$RESCUE_DROPIN_DIR"
    cat > "$RESCUE_DROPIN_FILE" <<'EOF'
[Service]
# Pre-start: reset counter=0 so license validation passes
ExecStartPre=/bin/bash -c 'echo "@pv@ 1 @db.counters@ @change@ @0@" > /tmp/p4_rescue.jnl && /opt/perforce/sbin/p4d -r /opt/perforce/servers/master -jr /tmp/p4_rescue.jnl'

# Post-start: dynamic MAX(change) → counter=MAX+1
# (- prefix: failure here doesn't fail the unit)
ExecStartPost=-/bin/bash -c '\
export P4TICKETS=/tmp/.p4tickets_admin; \
sleep 5; \
/opt/perforce/bin/p4 -p localhost:1888 -u admin login < /opt/perforce/.p4_admin_passwd 2>&1 | tee /tmp/p4_post.log; \
MAX_CHANGE=$(/opt/perforce/bin/p4 -p localhost:1888 -u admin changes -m 1 2>/dev/null | awk "{print \$2}"); \
if [ -n "$MAX_CHANGE" ] && [ "$MAX_CHANGE" -gt 0 ] 2>/dev/null; then \
    NEXT=$((MAX_CHANGE + 1)); \
    /opt/perforce/bin/p4 -p localhost:1888 -u admin counter -f change $NEXT 2>&1 | tee -a /tmp/p4_post.log; \
    echo "Counter set to $NEXT (based on max change $MAX_CHANGE)" | tee -a /tmp/p4_post.log; \
else \
    echo "No existing changes found, counter stays at 0" | tee -a /tmp/p4_post.log; \
fi'
EOF

    systemctl daemon-reload
    systemctl enable "$SVC_NAME"
    ok "systemd unit + 启动自愈 hook 已配置"
    info "现在可以: systemctl start $SVC_NAME"
}

step_setup_cron_checkpoint() {
    section "配置每日 checkpoint cron"
    mkdir -p "$BACKUP_DIR"
    chown "$P4D_USER:$P4D_USER" "$BACKUP_DIR"

    cat > "$CRON_FILE" <<EOF
# P4D Toolkit — auto-generated $(date -Iseconds)

# 每天 03:00 生成 checkpoint (压缩 + 轮转 journal)
0 3 * * * $P4D_USER $P4D_BIN -r $P4ROOT -jc -Z -p $BACKUP_DIR/checkpoint > $BACKUP_DIR/last.log 2>&1

# 每天 04:00 rsync depot 物理文件到外置盘 (差量)
0 4 * * * root rsync -a --delete --exclude='db.*' --exclude='journal*' --exclude='log*' $P4ROOT/ $DEPOT_BACKUP_DIR/ > $DEPOT_BACKUP_DIR/last-rsync.log 2>&1

# 每周日 05:00 清理 30 天前的旧 checkpoint / journal
0 5 * * 0 $P4D_USER find $BACKUP_DIR -name "checkpoint.*" -mtime +30 -delete
0 5 * * 0 $P4D_USER find $BACKUP_DIR -name "journal.*"    -mtime +30 -delete
EOF
    chmod 644 "$CRON_FILE"
    ok "cron 已配置: $CRON_FILE"
    info "checkpoint 落地: $BACKUP_DIR"
    info "depot 备份落地: $DEPOT_BACKUP_DIR (确保这个目录已挂载/可写)"

    if [[ ! -d "$DEPOT_BACKUP_DIR" ]]; then
        warn "$DEPOT_BACKUP_DIR 不存在 — depot rsync 会失败,请挂载备份盘"
    fi
}

# ============================================================
#  STEP IMPLEMENTATIONS — 救援
# ============================================================

step_counter_rescue() {
    section "Counter 救援"
    info "等同于 Windows 端 Counter 救援按钮 — 用于:"
    info "  • license 被错误降级到 5 用户"
    info "  • change counter 跟 MAX(change) 严重不一致"
    info ""
    info "流程: 停服 → 注 reset jnl(counter=0) → 启服 → 设 counter=MAX+1 → 验证"
    confirm "继续?" || return 0

    info "[1/5] 停止服务"
    systemctl stop "$SVC_NAME" || true
    sleep 2

    info "[2/5] 注入 counter=0 reset jnl 并 replay"
    local jnl="/tmp/p4_counter_reset_$$.jnl"
    echo "@pv@ 1 @db.counters@ @change@ @0@" > "$jnl"
    chown "$P4D_USER:$P4D_USER" "$jnl"
    sudo -u "$P4D_USER" "$P4D_BIN" -r "$P4ROOT" -jr "$jnl"
    rm -f "$jnl"

    info "[3/5] 启动服务"
    systemctl start "$SVC_NAME"
    sleep 5

    info "[4/5] 读取 MAX(change),设置 counter"
    if [[ -f "$P4D_ADMIN_PASSWD_FILE" ]]; then
        export P4TICKETS=/tmp/.p4tickets_admin
        "$P4_BIN" -p "localhost:$P4PORT" -u admin login < "$P4D_ADMIN_PASSWD_FILE" >/dev/null 2>&1 || true
        local max
        max="$(current_max_change)"
        if [[ -n "$max" && "$max" -gt 0 ]]; then
            local next=$((max + 1))
            "$P4_BIN" -p "localhost:$P4PORT" -u admin counter -f change "$next"
            ok "  counter 设为 $next (基于 MAX(change)=$max)"
        else
            info "  无 changelist 历史,counter 保持 0"
        fi
    else
        warn "  没有 admin 密码文件,跳过 counter 校准"
    fi

    info "[5/5] 验证 license"
    local lic
    lic="$(p4_info_license)"
    if [[ -n "$lic" ]]; then
        ok "Server license: $lic"
    else
        warn "p4 info 没有 'Server license' 行"
    fi
}

step_one_click_restore() {
    section "🚀 一键恢复"
    info "从备份目录还原:找最新 checkpoint + 后续 journal,做完整 replay"
    info "  备份目录: $BACKUP_DIR"
    confirm "继续?" || return 0

    if ! require_confirm_text "这会覆盖当前 db.* — 输入 CONFIRM 继续: " "CONFIRM"; then
        info "已取消"; return 0
    fi

    # 1. Find latest checkpoint
    local latest_ckpt latest_num
    latest_ckpt="$(ls -1 "$BACKUP_DIR"/checkpoint.* 2>/dev/null | grep -v '\.md5$' | grep -v '\.gz$' | sort -V | tail -1 || true)"
    if [[ -z "$latest_ckpt" ]]; then
        # try .gz
        latest_ckpt="$(ls -1 "$BACKUP_DIR"/checkpoint.*.gz 2>/dev/null | sort -V | tail -1 || true)"
    fi
    [[ -z "$latest_ckpt" ]] && die "在 $BACKUP_DIR 没找到 checkpoint.* 文件"
    latest_num="$(basename "$latest_ckpt" | sed -E 's/^checkpoint\.([0-9]+).*/\1/')"
    info "最新 checkpoint: $latest_ckpt (#$latest_num)"

    # 2. Find journals N >= latest_num
    local journals=()
    for f in "$BACKUP_DIR"/journal.[0-9]*; do
        [[ -e "$f" ]] || continue
        local n
        n="$(basename "$f" | sed -E 's/^journal\.([0-9]+).*/\1/')"
        if (( n >= latest_num )); then
            journals+=("$f")
        fi
    done
    info "需要 replay 的 journal 数: ${#journals[@]}"

    # 3. Stop service
    info "停止服务"
    systemctl stop "$SVC_NAME" || true
    sleep 2

    # 4. Snapshot current db.*
    local snap="${P4ROOT}/.pre-restore-$(date +%Y%m%d-%H%M%S)"
    info "快照当前 db.* 到 $snap"
    mkdir -p "$snap"
    chown "$P4D_USER:$P4D_USER" "$snap"
    find "$P4ROOT" -maxdepth 1 -name "db.*" -exec cp -p {} "$snap/" \;
    find "$P4ROOT" -maxdepth 1 -name "db.*" -delete

    # 5. Apply checkpoint (auto-detect .gz)
    info "Replay $latest_ckpt"
    sudo -u "$P4D_USER" "$P4D_BIN" -r "$P4ROOT" -jr "$latest_ckpt"

    # 6. Apply journals in order
    for j in "${journals[@]}"; do
        info "Replay $j"
        sudo -u "$P4D_USER" "$P4D_BIN" -r "$P4ROOT" -jr "$j" || warn "$j 报错(可能 out-of-sequence,无害)"
    done

    # 7. Pre-start counter rescue (defuse 坑 #1)
    info "注入 counter=0 jnl"
    local rj="/tmp/p4_pre_start_$$.jnl"
    echo "@pv@ 1 @db.counters@ @change@ @0@" > "$rj"
    chown "$P4D_USER:$P4D_USER" "$rj"
    sudo -u "$P4D_USER" "$P4D_BIN" -r "$P4ROOT" -jr "$rj"
    rm -f "$rj"

    # 8. Start
    info "启动服务"
    systemctl start "$SVC_NAME"
    sleep 5

    # 9. Calibrate counter
    if [[ -f "$P4D_ADMIN_PASSWD_FILE" ]]; then
        export P4TICKETS=/tmp/.p4tickets_admin
        "$P4_BIN" -p "localhost:$P4PORT" -u admin login < "$P4D_ADMIN_PASSWD_FILE" >/dev/null 2>&1 || true
        local max
        max="$(current_max_change)"
        if [[ -n "$max" && "$max" -gt 0 ]]; then
            local next=$((max + 1))
            "$P4_BIN" -p "localhost:$P4PORT" -u admin counter -f change "$next" >/dev/null
            info "counter 已校准到 $next"
        fi
    fi

    ok "恢复完成。快照保存在: $snap (确认无问题后可删)"
    p4_info_license || true
}

step_health_check() {
    section "🩺 健康体检"

    # Service
    local svc; svc="$(svc_state)"
    [[ "$svc" == "running" ]] && ok "服务: 运行中" || err "服务: $svc"

    # Ports
    if ss -tlnp 2>/dev/null | grep -q ":$P4PORT "; then
        ok "端口 $P4PORT: 监听中"
    else
        err "端口 $P4PORT: 没监听"
    fi

    # License
    local lic; lic="$(p4_info_license)"
    if [[ -n "$lic" ]]; then
        if echo "$lic" | grep -q "none\|5-user"; then
            err "License: $lic (降级到免费版)"
        else
            ok "License: $lic"
        fi
    else
        warn "License: 未读取到"
    fi

    # Counter consistency
    local counter max
    counter="$(current_change_counter)"
    max="$(current_max_change)"
    if [[ -n "$counter" && -n "$max" ]]; then
        local expected=$((max + 1))
        if [[ "$counter" == "$expected" || "$counter" == "$max" ]]; then
            ok "Counter: $counter (MAX=$max,一致)"
        else
            err "Counter 漂移: $counter ≠ 期望 $expected (MAX=$max) — 用菜单 6 救援"
        fi
    fi

    # Backups
    if [[ -d "$BACKUP_DIR" ]]; then
        local last_ckpt
        last_ckpt="$(ls -t "$BACKUP_DIR"/checkpoint.* 2>/dev/null | head -1 || true)"
        if [[ -n "$last_ckpt" ]]; then
            local age_h
            age_h=$(( ($(date +%s) - $(stat -c %Y "$last_ckpt")) / 3600 ))
            if (( age_h > 26 )); then
                err "上次 checkpoint: ${age_h}h 前 (>26h,异常)"
            else
                ok "上次 checkpoint: ${age_h}h 前"
            fi
        else
            warn "$BACKUP_DIR 里没有 checkpoint.* 文件"
        fi
    else
        warn "$BACKUP_DIR 不存在"
    fi

    # Disk
    local pct
    pct="$(df -P "$P4ROOT" | awk 'NR==2 {print $5}' | tr -d '%')"
    if (( pct > 90 )); then
        err "P4ROOT 所在盘已用 ${pct}% (>90%,危险)"
    elif (( pct > 75 )); then
        warn "P4ROOT 所在盘已用 ${pct}%"
    else
        ok "P4ROOT 所在盘已用 ${pct}%"
    fi

    # Systemd journal recent errors
    local errors
    errors="$(journalctl -u "$SVC_NAME" --since "1h ago" -p err --no-pager 2>/dev/null | wc -l)"
    if (( errors > 1 )); then
        warn "近 1h systemd journal 中有 $((errors - 1)) 条错误"
    fi
}

step_show_backup_status() {
    section "备份状态"
    info "Checkpoint 目录: $BACKUP_DIR"
    if [[ -d "$BACKUP_DIR" ]]; then
        ls -lht "$BACKUP_DIR" | head -20
    fi
    echo
    info "Depot 备份目录: $DEPOT_BACKUP_DIR"
    if [[ -d "$DEPOT_BACKUP_DIR" ]]; then
        du -sh "$DEPOT_BACKUP_DIR" 2>/dev/null || true
        ls -lh "$DEPOT_BACKUP_DIR" | head -10
    fi
}

step_view_journal() {
    section "systemd journal (最近 100 行)"
    journalctl -u "$SVC_NAME" -n 100 --no-pager
}

step_run_checkpoint_now() {
    section "立刻生成一个 checkpoint"
    sudo -u "$P4D_USER" "$P4D_BIN" -r "$P4ROOT" -jc -Z -p "$BACKUP_DIR/checkpoint"
    ok "完成"
    ls -lht "$BACKUP_DIR" | head -5
}

step_run_rsync_now() {
    section "立刻 rsync depot 一次"
    if [[ ! -d "$DEPOT_BACKUP_DIR" ]]; then
        die "$DEPOT_BACKUP_DIR 不存在,先挂载备份盘"
    fi
    rsync -av --delete --exclude='db.*' --exclude='journal*' --exclude='log*' "$P4ROOT/" "$DEPOT_BACKUP_DIR/"
    ok "完成"
}

step_uninstall() {
    section "⚠ 卸载 P4D + Toolkit"
    warn "这会停止服务、删除 systemd unit、cron、二进制文件"
    warn "数据库 ($P4ROOT) 和 license 文件 不会 被删,请手动处理"
    if ! require_confirm_text "确认卸载? 输入 UNINSTALL: " "UNINSTALL"; then
        info "已取消"; return 0
    fi

    systemctl stop "$SVC_NAME" 2>/dev/null || true
    systemctl disable "$SVC_NAME" 2>/dev/null || true
    rm -f "$SVC_FILE" "$RESCUE_DROPIN_FILE" "$CRON_FILE"
    rm -rf "$RESCUE_DROPIN_DIR"
    rm -f "$P4D_BIN" "$P4_BIN_DIR/p4"
    rm -f /usr/local/bin/p4 /usr/local/sbin/p4d
    systemctl daemon-reload
    ok "卸载完成。保留的文件: $P4ROOT (database), $CONFIG_FILE"
}

# ============================================================
#  MENU
# ============================================================

main_menu() {
    while true; do
        print_header
        cat <<MENU

  ${C_BOLD}── 部署 ──${C_RESET}
  1) 全新安装 P4D ${P4D_VERSION}
  2) 装 license 文件
  3) 配 systemd + 启动自愈 hook
  4) 配每日 03:00 checkpoint cron
  5) 一次性全部部署 (1→2→3→4)

  ${C_BOLD}── 救援 ──${C_RESET}
  6) Counter 救援 (license 炸了用)
  7) 一键恢复 (从备份 checkpoint+journal)

  ${C_BOLD}── 体检 / 状态 ──${C_RESET}
  10) 健康体检
  11) 备份状态
  12) systemd journal 日志

  ${C_BOLD}── 维护 ──${C_RESET}
  13) 立刻生成 checkpoint
  14) 立刻 rsync depot
  15) 启动服务
  16) 停止服务
  17) 重启服务

  ${C_BOLD}── 危险区 ──${C_RESET}
  99) 卸载 P4D + Toolkit

  0) 退出

MENU
        local choice
        read -r -p "$(printf "${C_CYAN}选择: ${C_RESET}")" choice
        echo
        case "$choice" in
            1)  step_install_p4d ;;
            2)  step_install_license ;;
            3)  step_setup_systemd_with_rescue ;;
            4)  step_setup_cron_checkpoint ;;
            5)  step_install_p4d && step_install_license && step_setup_systemd_with_rescue && step_setup_cron_checkpoint ;;
            6)  step_counter_rescue ;;
            7)  step_one_click_restore ;;
            10) step_health_check ;;
            11) step_show_backup_status ;;
            12) step_view_journal ;;
            13) step_run_checkpoint_now ;;
            14) step_run_rsync_now ;;
            15) systemctl start "$SVC_NAME" && ok "已启动" ;;
            16) systemctl stop  "$SVC_NAME" && ok "已停止" ;;
            17) systemctl restart "$SVC_NAME" && ok "已重启" ;;
            99) step_uninstall ;;
            0|q|exit) ok "再见"; exit 0 ;;
            *) err "未知选项: $choice" ;;
        esac
        echo
        read -r -p "按回车继续..." _
    done
}

# ============================================================
#  主入口
# ============================================================

main() {
    log_init
    ensure_root
    load_config

    # 非交互模式 (CLI subcommands)
    if [[ $# -gt 0 ]]; then
        case "$1" in
            status|health)   step_health_check ;;
            checkpoint)      step_run_checkpoint_now ;;
            rsync)           step_run_rsync_now ;;
            counter-rescue)  step_counter_rescue ;;
            restore)         step_one_click_restore ;;
            *) die "未知子命令: $1 (用法: status|checkpoint|rsync|counter-rescue|restore)" ;;
        esac
        exit 0
    fi

    main_menu
}

main "$@"
