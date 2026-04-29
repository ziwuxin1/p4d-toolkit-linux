# P4D 从 Windows 迁移到 Ubuntu 完整部署文档

> 适用版本: **P4D 2024.1/2876055**(Linux x86_64)
>
> 适用场景: Windows P4D 服务器迁移到 Ubuntu 服务器,保留所有用户、workspace、changelist 历史和物理文件
>
> **使用前请通读"重要踩坑提醒"章节**

---

## 目录

1. [文档说明 + 关键概念](#1-文档说明)
2. [前置准备](#2-前置准备)
3. [⚠️ 重要踩坑提醒](#3-重要踩坑提醒)
4. [Phase 0: 安装 P4D](#phase-0-安装-p4d)
5. [Phase 1: 系统配置](#phase-1-系统配置)
6. [Phase 2: License + Systemd 自动救援](#phase-2-license--systemd-自动救援) ⭐ 最关键
7. [Phase 3: 创建初始 admin](#phase-3-创建初始-admin)
8. [Phase 4a: Depot 定义重建](#phase-4a-depot-定义重建)
9. [Phase 4b: 用户/组/权限恢复](#phase-4b-用户组权限恢复)
10. [Phase 4c: Workspaces 恢复](#phase-4c-workspaces-恢复)
11. [Phase 4d: Changelist 历史恢复](#phase-4d-changelist-历史恢复)
12. [Phase 4e: 物理 Depot 文件迁移](#phase-4e-物理-depot-文件迁移)
13. [验证 + 测试](#验证--测试)
14. [紧急救援流程](#紧急救援流程)
15. [每日自动备份](#每日自动备份)
16. [客户端使用指南](#客户端使用指南)

---

## 1. 文档说明

### 服务器规格(本测试环境)

| 项目 | 值 |
|------|---|
| OS | Ubuntu 24.04.3 LTS |
| 服务器 IP | `192.168.1.241` |
| P4D 版本 | 2024.1/2876055 |
| 端口 | 1888 |
| 管理员 | `admin` / `!Gei181501` |
| License | 1000 users(2034/10/17 过期) |
| 历史 changelist | 1395 个 |
| Users | 104 |
| Workspaces | 113 |
| Depots | 13 |

### 关键概念

- **P4ROOT**: P4D 数据目录,本文档统一用 `/opt/perforce/servers/master/`
- **Case-insensitive 模式**: 用 `-C1` 初始化,模拟 Windows 行为(必须,否则文件大小写冲突)
- **Counter**: P4D 内部计数器,`change` counter 是下一个 changelist 编号
- **Journal**: 实时事务日志,跟 db.* 文件配合保证数据一致性
- **Checkpoint**: 完整 metadata 快照,纯文本,平台无关

---

## 2. 前置准备

### 2.1 服务器要求

```bash
# Ubuntu 24.04+ 推荐,22.04 也可
# 至少 4GB 内存
# 磁盘空间 = 物理 depot 总大小 + 5GB

# 必装包
apt update
apt install -y curl wget python3 cifs-utils unzip
```

### 2.2 必备文件清单

从原 Windows P4D 服务器或备份中获取:

| 文件 | 来源 | 说明 |
|------|------|-----|
| `helix-core-server-2024.1.tgz` | Perforce 官方 FTP 或自有 | P4D 二进制包 |
| `checkpoint.NNN` + `.md5` | 原 P4D 的 backup 目录 | 完整 metadata 快照 |
| `license` | 原 P4ROOT | License 文件(rehost 后) |
| `old_db_user.jnl` + `.md5` | 单独 export 出来的(可选) | 老用户单独 jnl |
| `old_db_group.jnl` + `.md5` | 同上 | 老组 |
| `old_db_protect.jnl` + `.md5` | 同上 | 老权限 |
| **整个 depot 物理目录** | 原 Windows P4ROOT 下 | 文件实际内容(`,d` 目录) |

**重要**:checkpoint 中能看到原服务器路径。例如:
```
@nx@ 0 1777357360 @58@ 2 0 0 0 @D:\P4D\Root@ @journal@ @@ @@ @@
                                  ↑ 这是原 P4ROOT
```

### 2.3 命令行约定

所有命令以 `root` 身份运行,除非特别说明。

---

## 3. ⚠️ 重要踩坑提醒

### 🚨 坑 #1: License 跟 counter 值耦合(最大的坑)

**现象**: 设了 `change counter = 1543` 后,**重启时 P4D 拒绝启动**,日志说 `exceeded usage limits`。

**原因**: 这份 license 在 P4D 启动验证时,会跟 counter 状态做某种校验。高 counter 值会让验证失败,P4D 回退到 5 用户免费模式 → 拒启。

**解决**: 用 systemd hook **每次启动前重置 counter 为 0,启动后动态查 MAX(change) 设回 MAX+1**。详见 Phase 2.4。

⚠️ **特别注意**: ExecStartPost 必须**动态检测** MAX(change),不能硬编码固定值。否则学生提交后 counter 自然增长(1543 → 5000+),重启会被错误地降回硬编码值,导致下一次 submit 撞号失败。

### 🚨 坑 #2: 不能 replay 完整的 db.counters

**现象**: Replay db.counters 后服务器无法启动。

**原因**: db.counters 中的 `journal`、`upgrade`、`lastCheckpointAction` 等"状态指标"会让 P4D 启动时做内部一致性检查并失败。

**解决**: 只 replay 数据表(db.change、db.desc 等),**完全跳过 db.counters**。Counter 用 `p4 counter -f change N` 单独设。

### 🚨 坑 #3: 物理 depot 目录必须全小写

**现象**: 文件传到 `MAXs_GGJ_2026/` 但 P4D 报 `open for read: maxs_ggj_2026/...: No such file or directory`。

**原因**: P4D 在 case-insensitive 模式下,**存储路径全部用小写**。Linux 文件系统大小写敏感,目录大小写必须匹配。

**解决**: 把 depot 物理目录改成全小写。例如:
- 数据库里 depot 名是 `MAXs_GGJ_2026`(case-insensitive 能匹配)
- 磁盘目录必须是 `maxs_ggj_2026`(全小写)

### 🚨 坑 #4: P4 Journal 多行记录不能用 grep 提取

**现象**: 用 `grep '@db.domain@'` 从 checkpoint 提取记录,结果 P4D replay 报 `Bad quoting at line N`。

**原因**: P4 Journal 中**长描述/多行 view**等字段可以跨行,grep 按行处理破坏了记录完整性。

**解决**: 用 Python 写正确的解析器,识别 `@...@` 引号配对。详见 Phase 4c。

### 🚨 坑 #5: Path-filtered history 需要 submit 触发激活

**现象**: 导入完 db.rev 后,`p4 changes //depot/...` 返回空,但 `p4 changes -m N` 全局视图正常。

**原因**: P4D 内部 path-filter 索引是 lazy 的,需要 submit 一次新文件才会激活。

**解决**: 每个 depot 迁移完后 submit 一个 marker 文件触发索引重建。

### 🚨 坑 #6: License 文件位置必须是 `$P4ROOT/license`

**现象**: License 放在 `/opt/perforce/checkpoints/license` 等其他位置,P4D 不识别。

**解决**: 必须放在 `$P4ROOT/license`(本文档中是 `/opt/perforce/servers/master/license`)。

### 🚨 坑 #7: perforce 用户读不到 root 家目录里的 checkpoint

**现象**: `sudo -u perforce p4d -jr /root/checkpoint.149` 报 `Permission denied`。

**解决**: 把 checkpoint 复制到 `/opt/perforce/checkpoints/`(perforce 能读)。

### 🚨 坑 #8: P4 密码包含特殊字符的处理

**现象**: 密码 `!Gei181501` 在 systemd ExecStartPost 里传不进去,因为 bash 的 `!` 历史扩展和 systemd 的引号处理。

**解决**: 把密码存到文件 `/opt/perforce/.p4_admin_passwd`,用 `<` 重定向输入。

### 🚨 坑 #9: P4TICKETS 默认路径不可写

**现象**: `Unrecoverable lock error '/opt/perforce/.p4tickets.lck' Permission denied`。

**解决**: ExecStartPost 中显式设 `P4TICKETS=/tmp/.p4tickets_admin`。

---

## Phase 0: 安装 P4D

### 0.1 下载二进制

```bash
# 官方 FTP 下载(2024.1 系列最新)
mkdir -p /tmp/p4_install && cd /tmp/p4_install
curl -sSL -o helix-core-server.tgz \
    https://ftp.perforce.com/perforce/r24.1/bin.linux26x86_64/helix-core-server.tgz

# 或者用你已有的 tgz
# cp /path/to/helix-core-server-2024.1.tgz /tmp/p4_install/helix-core-server.tgz

# 解压并验证版本
tar xzf helix-core-server.tgz
./p4d -V | grep "^Rev\."
# 期望: Rev. P4D/LINUX26X86_64/2024.1/2876055 (2026/01/09).
```

### 0.2 安装二进制

```bash
mkdir -p /opt/perforce/sbin /opt/perforce/bin
install -m 755 p4d p4broker p4p /opt/perforce/sbin/
install -m 755 p4 /opt/perforce/bin/

# 全局符号链接
ln -sf /opt/perforce/bin/p4 /usr/local/bin/p4
ln -sf /opt/perforce/sbin/p4d /usr/local/sbin/p4d

# 验证
p4 -V | grep "^Rev\."
p4d -V | grep "^Rev\."
```

### 0.3 创建 perforce 系统用户

```bash
useradd -r -m -d /opt/perforce -s /bin/bash perforce 2>/dev/null || echo "已存在"

# ⚠️ 关键: /opt/perforce 必须可写,否则 P4TICKETS 等文件无法创建
chown perforce:perforce /opt/perforce
```

### 0.4 创建 P4ROOT

```bash
mkdir -p /opt/perforce/servers/master
chown -R perforce:perforce /opt/perforce/servers
chown -R perforce:perforce /opt/perforce/sbin /opt/perforce/bin
```

### 0.5 初始化 case-insensitive 数据库

```bash
sudo -u perforce /opt/perforce/sbin/p4d -r /opt/perforce/servers/master -C1 -xi
# Server switched to Unicode mode.
```

⚠️ **`-C1` 必须在第一次创建时指定**,以后无法修改。

---

## Phase 1: 系统配置

### 1.1 创建 systemd unit(基础版,后面会加 hook)

```bash
cat > /etc/systemd/system/p4d.service <<'EOF'
[Unit]
Description=Helix Core (Perforce) Server
After=network.target

[Service]
Type=forking
User=perforce
Group=perforce
Environment=P4ROOT=/opt/perforce/servers/master
Environment=P4PORT=1888
Environment=P4JOURNAL=/opt/perforce/servers/master/journal
Environment=P4LOG=/opt/perforce/servers/master/log
ExecStart=/opt/perforce/sbin/p4d -r /opt/perforce/servers/master -p 1888 -d
ExecStop=/opt/perforce/bin/p4 -p 1888 admin stop
Restart=on-failure
RestartSec=5

LimitNOFILE=65536
LimitNPROC=8192

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable p4d
```

### 1.2 防火墙

```bash
ufw status | grep -q "Status: active" && ufw allow 1888/tcp comment 'Perforce'
```

### 1.3 环境变量

```bash
grep -q "P4PORT=localhost:1888" /root/.bashrc || \
    echo 'export P4PORT=localhost:1888' >> /root/.bashrc
export P4PORT=localhost:1888
```

---

## Phase 2: License + Systemd 自动救援

### 2.1 ⭐ 这是整个文档最关键的章节

放好 license 文件后,**必须**配置 systemd 自动救援 hook,否则重启 P4D 时 license 会炸,服务无法启动。

### 2.2 装 license 文件

```bash
# 把 license 文件复制到 P4ROOT(必须叫 license,不能改名)
cp /path/to/your/license /opt/perforce/servers/master/license
chown perforce:perforce /opt/perforce/servers/master/license
chmod 644 /opt/perforce/servers/master/license

# 验证字段(签名部分会很长,只看前几个关键字段)
grep -E "^(License|IPaddress|Hostname|Users|ExpireDate|Support):" \
    /opt/perforce/servers/master/license
# 必须看到:
# License: <一串 hex>
# IPaddress: 192.168.1.241    ← 必须匹配你的服务器 IP
# Users: 1000
```

### 2.3 创建 admin 密码文件

```bash
# 密码存文件,避免 systemd 处理 ! 的麻烦
echo '!Gei181501' > /opt/perforce/.p4_admin_passwd
chown perforce:perforce /opt/perforce/.p4_admin_passwd
chmod 600 /opt/perforce/.p4_admin_passwd
```

### 2.4 创建 systemd 自动救援 hook(关键!)

⚠️ **特别注意**: 不要硬编码 counter 值(比如 1543)。学生提交后 counter 会自然增长(1544, 1545, ..., 5000+),如果硬编码成固定值,重启后会被错误地"降回"老值,导致下一次 submit 撞号失败。**正确做法是动态读取数据库里的 MAX(change),把 counter 设到 MAX+1**。

```bash
mkdir -p /etc/systemd/system/p4d.service.d

cat > /etc/systemd/system/p4d.service.d/rescue.conf <<'EOF'
[Service]
# 启动前: 把 change counter 重置为 0 (让 license 验证通过)
ExecStartPre=/bin/bash -c 'echo "@pv@ 1 @db.counters@ @change@ @0@" > /tmp/p4_rescue.jnl && /opt/perforce/sbin/p4d -r /opt/perforce/servers/master -jr /tmp/p4_rescue.jnl'

# 启动后: 动态检测 MAX(change),把 counter 设到 MAX+1
# 这样无论学生提交多少 changelist,重启后都能正确接续
# 用 - 前缀让失败不影响服务
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
```

⚠️ **要点说明**:

1. **`ExecStartPre` 重置 counter 为 0**: 让 P4D 启动时 license 验证能通过(counter 不能太高)
2. **`ExecStartPost` 动态查 MAX(change) → 设 counter = MAX+1**: 自动适配学生不停提交带来的 counter 增长
3. **`P4TICKETS=/tmp/...`**: 避开 `/opt/perforce/.p4tickets.lck` 权限问题
4. **`<` 重定向密码文件**: 避开 `!` 在 bash 里的特殊处理
5. **`-` 前缀让 ExecStartPost 失败不影响服务**: 即使 post 失败,服务也是 active

⚠️ **为什么要动态检测**:

```
现在:    max change = 1542 → counter 自动设为 1543 ✅
6 个月后: max change = 4999(学生交了很多作业)→ counter 自动设为 5000 ✅
2 年后:   max change = 18472 → counter 自动设为 18473 ✅
```

如果硬编码 1543:
```
6 个月后: max change = 4999, 重启
ExecStartPost: counter -f change 1543  ← 错误地降回 1543!
学生 submit → 试用 change 1544 → "Sequence error: change 1544 already exists"
要失败到 5001 次才能成功 submit ❌
```

**短暂的 race condition**: 启动后约 5 秒窗口内 counter 是 0。这时候如果有学生 submit,会得到 change 1 → 撞号失败。实际场景重启很罕见(几个月一次),命中 5 秒窗口的概率几乎为 0。即使踩到,学生提示 "sequence error" 重试即可,**没有数据损坏**。

### 2.5 启动并验证

```bash
systemctl start p4d
sleep 10
systemctl is-active p4d
# 应该是: active

p4 info | grep -E "Server license|users"
# 应该看到: Server license: <name> 1000 users (...)
```

### 2.6 关键测试: 多次重启看 license 不炸

```bash
for i in 1 2 3; do
    echo "===== 第 $i 次重启 ====="
    systemctl restart p4d
    sleep 10
    printf '!Gei181501\n' | p4 -u admin login >/dev/null 2>&1
    echo "Active:  $(systemctl is-active p4d)"
    echo "License: $(p4 -u admin info | grep 'Server license:')"
    echo "Counter: $(p4 -u admin counter change)"
done
# 3 次都必须 active 且 license 显示 1000 users
```

---

## Phase 3: 创建初始 admin

### 3.1 创建 admin 用户

```bash
p4 -u admin user -f -i <<EOF
User:	admin
Email:	admin@localhost
FullName:	System Administrator
EOF
```

### 3.2 设密码

```bash
printf '!Gei181501\n!Gei181501\n' | p4 -u admin passwd
```

### 3.3 设 super 权限

```bash
p4 -u admin protect -i <<'EOF'
Protections:
	super user admin * //...
	write user * * //...
EOF
```

### 3.4 登录

```bash
printf '!Gei181501\n' | p4 -u admin login
```

---

## Phase 4a: Depot 定义重建

### 4a.1 为什么不直接 replay db.depot

Checkpoint 中的 `@db.depot@` 记录是 schema 版本 2(`@pv@ 2`),P4D 2024.1 静默拒绝(replay 退出码 0 但数据不进库)。**手动重建**最稳。

### 4a.2 把 checkpoint 放到 perforce 能读的位置

```bash
mkdir -p /opt/perforce/checkpoints
cp /path/to/checkpoint.149 /opt/perforce/checkpoints/
cp /path/to/checkpoint.149.md5 /opt/perforce/checkpoints/
chown -R perforce:perforce /opt/perforce/checkpoints
chmod 644 /opt/perforce/checkpoints/*

# 校验
sudo -u perforce md5sum /opt/perforce/checkpoints/checkpoint.149
cat /opt/perforce/checkpoints/checkpoint.149.md5
# 两个 hash 必须一致
```

### 4a.3 提取原 depot 列表(参考)

```bash
grep -a '@db\.depot@' /opt/perforce/checkpoints/checkpoint.149 | head -20
```

### 4a.4 批量创建 depot

根据你的实际 depot 列表修改,例如:

```bash
# 注意: 名字大小写跟原始一致
DEPOTS="2025_CAFA_Game_Design \
2025_Environment_Art_Class \
2025_GameDesign_Class \
2025_TA_Environment_Art_Class \
2026_GameDesign_Class \
2026_TA_Environment_Art_Class \
MAXs_GGJ_2026 \
MAXs_Instroctors \
MAXs_Portfolio_And_Career \
MAXs_SingleProject"

for name in $DEPOTS; do
    p4 -u admin depot -i <<EOF
Depot:	$name
Owner:	admin
Date:	$(date +%Y/%m/%d)
Description:
	Migrated from Windows P4D
Type:	local
Address:	local
Suffix:	.p4s
StreamDepth:	//$name/1
Map:	$name/...
EOF
    echo "✓ $name"
done

# (可选) 删默认 depot
p4 -u admin depot -d depot 2>/dev/null

p4 -u admin depots -a
```

⚠️ **重要**: 系统 depot `.p4-extensions`、`.p4-traits`、`repo` 是 P4D 2024.1 自动创建的,**不要重建**。

---

## Phase 4b: 用户/组/权限恢复

### 4b.1 用单独的 .jnl 文件 replay

如果你有 `old_db_user.jnl`、`old_db_group.jnl`、`old_db_protect.jnl`(从原服务器单独 export 的):

```bash
# 复制 jnl 文件到能读的位置
mkdir -p /opt/perforce/checkpoints/old_export
cp /path/to/old_db_*.jnl /opt/perforce/checkpoints/old_export/
chown -R perforce:perforce /opt/perforce/checkpoints/old_export
chmod 644 /opt/perforce/checkpoints/old_export/*

# 停服务
systemctl stop p4d
sleep 2

# 按顺序 replay
for tbl in user group protect; do
    echo "---- $tbl ----"
    sudo -u perforce /opt/perforce/sbin/p4d -r /opt/perforce/servers/master \
        -jr /opt/perforce/checkpoints/old_export/old_db_${tbl}.jnl 2>&1
done

# 启动
systemctl start p4d
sleep 10
printf '!Gei181501\n' | p4 -u admin login

# 验证
echo "Users:    $(p4 -u admin users | wc -l)"
echo "Groups:   $(p4 -u admin groups | wc -l)"
```

### 4b.2 处理 protect 表中的 deny 规则

老 protect 表可能有这种规则:
```
list user * * -//...
```

这条规则会**拒绝所有人 list 权限**,即使你是 super 用户也可能受影响。

**保险起见**,在 admin 之外保留这条规则,但把 admin 提到表的最前面:

```bash
p4 -u admin protect -o > /tmp/protect.txt
# 手动编辑 /tmp/protect.txt,把 super user admin * //... 放到最前面
# 然后:
p4 -u admin protect -i < /tmp/protect.txt
```

---

## Phase 4c: Workspaces 恢复

### 4c.1 关键: 安装 Python 解析器

P4 Journal 中长字段(如 description)**可以跨行**,简单的 grep 提取会破坏记录。**必须用正确的解析器**:

```bash
cat > /tmp/extract_p4_records.py <<'PYEOF'
#!/usr/bin/env python3
"""
正确提取 P4 checkpoint 里指定表的记录(处理多行记录)
用法: python3 extract_p4_records.py <checkpoint> <table_name>
"""
import sys

if len(sys.argv) != 3:
    sys.exit("Usage: extract_p4_records.py <checkpoint> <table_name>")

ckpt_path = sys.argv[1]
table = sys.argv[2]
table_marker = f'@{table}@'

with open(ckpt_path, 'r', encoding='latin-1') as f:
    data = f.read()

# 解析: 遇到 @ 切换 in_quote,@@ 是转义,不在 quote 里时遇到 \n 是记录边界
records = []
current = []
in_quote = False
i = 0
n = len(data)
while i < n:
    c = data[i]
    if c == '@':
        if i + 1 < n and data[i + 1] == '@':
            current.append('@@')
            i += 2
            continue
        in_quote = not in_quote
        current.append(c)
        i += 1
    elif c == '\n' and not in_quote:
        records.append(''.join(current))
        current = []
        i += 1
    else:
        current.append(c)
        i += 1
if current:
    records.append(''.join(current))

matched = [r for r in records if table_marker in r]
print(f"# 找到 {len(matched)} 条 {table} 记录", file=sys.stderr)

for r in matched:
    print(r)
PYEOF

chmod +x /tmp/extract_p4_records.py
```

### 4c.2 提取 + replay db.domain 和 db.view

```bash
systemctl stop p4d
sleep 2

# 提取 db.domain (clients/labels/branches/streams)
python3 /tmp/extract_p4_records.py /opt/perforce/checkpoints/checkpoint.149 db.domain \
    > /opt/perforce/checkpoints/02_domain.jnl 2>/dev/null

# 提取 db.view (workspace 视图)
python3 /tmp/extract_p4_records.py /opt/perforce/checkpoints/checkpoint.149 db.view \
    > /opt/perforce/checkpoints/02_view.jnl 2>/dev/null

# 修权限
chown perforce:perforce /opt/perforce/checkpoints/02_*.jnl
chmod 644 /opt/perforce/checkpoints/02_*.jnl

# Replay
sudo -u perforce /opt/perforce/sbin/p4d -r /opt/perforce/servers/master \
    -jr /opt/perforce/checkpoints/02_domain.jnl
sudo -u perforce /opt/perforce/sbin/p4d -r /opt/perforce/servers/master \
    -jr /opt/perforce/checkpoints/02_view.jnl

# 启动
systemctl start p4d
sleep 10
printf '!Gei181501\n' | p4 -u admin login

# 验证
echo "Clients:  $(p4 -u admin clients | wc -l)"
echo "Streams:  $(p4 -u admin streams | wc -l)"
```

---

## Phase 4d: Changelist 历史恢复

### 4d.1 ⚠️ 不要 replay db.counters!

整个迁移最大的坑就在这里。**db.counters 中的 `journal`、`upgrade`、`lastCheckpointAction` 会破坏 license 验证**。

**只 replay 数据表**,counter 用 `p4 counter -f` 单独设。

### 4d.2 提取相关表

```bash
systemctl stop p4d
sleep 2

# 提取所有 changelist 相关表(注意没有 counters!)
for tbl in db.change db.changex db.changeidx db.desc db.fix db.fixrev db.job; do
    out="/opt/perforce/checkpoints/03_${tbl#db.}.jnl"
    python3 /tmp/extract_p4_records.py /opt/perforce/checkpoints/checkpoint.149 "$tbl" \
        > "$out" 2>/dev/null
    echo "$tbl: $(wc -l < "$out") 行"
done

chown perforce:perforce /opt/perforce/checkpoints/03_*.jnl
chmod 644 /opt/perforce/checkpoints/03_*.jnl
```

### 4d.3 按顺序 replay

```bash
for tbl in change changex changeidx desc job fix fixrev; do
    f="/opt/perforce/checkpoints/03_${tbl}.jnl"
    if [ -s "$f" ]; then
        echo "---- Replay $tbl ----"
        sudo -u perforce /opt/perforce/sbin/p4d -r /opt/perforce/servers/master \
            -jr "$f"
    fi
done

systemctl start p4d
sleep 10
printf '!Gei181501\n' | p4 -u admin login

# 验证
echo "Changelists: $(p4 -u admin changes | wc -l)"
p4 -u admin describe -s 1 2>&1 | head -3   # 看最早的 change
```

### 4d.4 ⚠️ Counter 处理(注意!)

**Counter 完全由 Phase 2.4 的 systemd hook 自动管理**,你不需要手动设置。

**hook 工作原理**(再次强调):
1. 每次启动 P4D 前: counter 重置为 0(让 license 验证通过)
2. 每次启动 P4D 后: 查 MAX(change),把 counter 设为 MAX+1(让新 submit 能继续)

**所以你导完 1395 changelist 后**:
- 重启 P4D
- ExecStartPost 自动检测 max change = 1542
- counter 自动设为 1543
- 学生新 submit → change 1544、1545、... 一路涨

**学生提交一年后**:
- max change 涨到 5000
- 重启 → counter 自动设为 5001
- **永不需要人工干预**

⚠️ **千万不要手动跑** `p4 counter -f change <fixed_value>` —— 这会让重启时 license 炸。除非你刚好在调试,且知道自己在干嘛。

---

## Phase 4e: 物理 Depot 文件迁移

### 4e.1 约定: 目录全小写

⚠️ **关键**: P4D case-insensitive 模式下,**磁盘上 depot 目录必须全小写**。

例如 depot 名 `MAXs_GGJ_2026`,磁盘目录必须是 `/opt/perforce/servers/master/maxs_ggj_2026/`。

### 4e.2 单 depot 迁移流程

#### 第 1 步: 创建小写目录

```bash
DEPOT="MAXs_GGJ_2026"
LOWER=$(echo "$DEPOT" | tr '[:upper:]' '[:lower:]')

mkdir -p /opt/perforce/servers/master/$LOWER
chown perforce:perforce /opt/perforce/servers/master/$LOWER
```

#### 第 2 步: SCP 物理文件(从 Windows)

在 **Windows PowerShell** 跑(不是 MobaXterm SFTP,SCP 快得多):

```powershell
# 在 PowerShell 里(Windows 10 1809+ 自带 scp)
scp -r "C:\path\to\maxs_ggj_2026\*" root@192.168.1.241:/opt/perforce/servers/master/maxs_ggj_2026/
```

⚠️ **常见错误**: 把整个 `maxs_ggj_2026` 文件夹拖进去,造成嵌套 `maxs_ggj_2026/maxs_ggj_2026/...`。**拖文件夹里的内容**,不是文件夹本身(用 `*` 通配符)。

#### 第 3 步: 修权限

```bash
chown -R perforce:perforce /opt/perforce/servers/master/$LOWER
```

#### 第 4 步: 提取 + replay 4 张 rev 表

```bash
systemctl stop p4d
sleep 2

# 4 张关键索引表
for tbl in db.rev db.revcx db.revdx db.revhx; do
    out="/opt/perforce/checkpoints/04_${tbl#db.}_${LOWER}.jnl"
    python3 /tmp/extract_p4_records.py /opt/perforce/checkpoints/checkpoint.149 "$tbl" 2>/dev/null \
        | grep -i "${DEPOT}" > "$out"
    echo "$tbl: $(wc -l < "$out") 条"
    chown perforce:perforce "$out"
    chmod 644 "$out"
done

# Replay
for tbl in db.rev db.revcx db.revdx db.revhx; do
    out="/opt/perforce/checkpoints/04_${tbl#db.}_${LOWER}.jnl"
    if [ -s "$out" ]; then
        sudo -u perforce /opt/perforce/sbin/p4d -r /opt/perforce/servers/master -jr "$out"
    fi
done

systemctl start p4d
sleep 10
printf '!Gei181501\n' | p4 -u admin login

# 验证
echo "$DEPOT 文件数: $(p4 -u admin files //$DEPOT/... 2>&1 | wc -l)"
```

#### 第 5 步: 测试 sync

```bash
mkdir -p /tmp/p4test_$LOWER
p4 -u admin client -i <<EOF
Client:	test_${LOWER}
Owner:	admin
Root:	/tmp/p4test_${LOWER}
View:
	//$DEPOT/... //test_${LOWER}/...
EOF

# Sync 一个文件试试
SAMPLE=$(p4 -u admin files //$DEPOT/... 2>&1 | head -1 | sed 's/#.*//')
p4 -u admin -c test_${LOWER} sync -f "$SAMPLE"
ls -la /tmp/p4test_${LOWER}/
```

#### 第 6 步: ⭐ Submit 一个 marker 文件(激活 path-filtered history)

```bash
# 这一步是 path-filtered history 工作的关键
echo "Migration marker $(date)" > /tmp/p4test_${LOWER}/.migrated
p4 -u admin -c test_${LOWER} add /tmp/p4test_${LOWER}/.migrated 2>&1

# Submit (会用 systemd hook 设的 counter,从 1544 开始)
p4 -u admin -c test_${LOWER} submit -d "Migration marker - triggers history index" 2>&1

# 验证 history 现在工作
p4 -u admin changes -m 5 //$DEPOT/...
# 应该看到老 changelist 都列出来了
```

### 4e.3 一键迁移脚本

```bash
cat > /root/migrate_depot.sh <<'SCRIPT_EOF'
#!/bin/bash
# 用法: bash /root/migrate_depot.sh <DepotName>
# 例如: bash /root/migrate_depot.sh 2025_CAFA_Game_Design

set -e

DEPOT_NAME="$1"
[ -z "$DEPOT_NAME" ] && { echo "Usage: $0 <DepotName>"; exit 1; }

LOWERCASE=$(echo "$DEPOT_NAME" | tr '[:upper:]' '[:lower:]')
DEPOT_DIR="/opt/perforce/servers/master/$LOWERCASE"
CHECKPOINT="/opt/perforce/checkpoints/checkpoint.149"
ADMIN_PASSWD_FILE="/opt/perforce/.p4_admin_passwd"

echo "迁移 depot: $DEPOT_NAME → $DEPOT_DIR"

# 检查物理文件
if [ ! -d "$DEPOT_DIR" ] || [ -z "$(ls -A $DEPOT_DIR 2>/dev/null)" ]; then
    echo "❌ $DEPOT_DIR 不存在或为空,先 SCP 文件过来"
    exit 1
fi

# 修权限
chown -R perforce:perforce "$DEPOT_DIR"

# 检查嵌套
NESTED=$(find "$DEPOT_DIR" -maxdepth 2 -type d -iname "$DEPOT_NAME" 2>/dev/null | head -1)
if [ -n "$NESTED" ] && [ "$NESTED" != "$DEPOT_DIR" ]; then
    echo "⚠️ 发现嵌套: $NESTED"
    echo "   修复: cd $DEPOT_DIR && mv $(basename $NESTED)/* . && rmdir $(basename $NESTED)"
    exit 1
fi

# 停服务
systemctl stop p4d
sleep 2

# 提取 + replay 4 张表
for tbl in db.rev db.revcx db.revdx db.revhx; do
    OUT="/opt/perforce/checkpoints/migrate_${LOWERCASE}_${tbl#db.}.jnl"
    python3 /tmp/extract_p4_records.py "$CHECKPOINT" "$tbl" 2>/dev/null \
        | grep -i "${DEPOT_NAME}" > "$OUT"
    LINES=$(wc -l < "$OUT")
    if [ "$LINES" -gt 0 ]; then
        chown perforce:perforce "$OUT"
        echo "$tbl: $LINES 条"
        sudo -u perforce /opt/perforce/sbin/p4d -r /opt/perforce/servers/master \
            -jr "$OUT" 2>&1 | tail -2
    fi
done

# 启动
systemctl start p4d
sleep 10
printf '!Gei181501\n' | p4 -u admin login >/dev/null 2>&1

echo ""
echo "===== 验证 ====="
echo "Active:  $(systemctl is-active p4d)"
echo "License: $(p4 -u admin info | grep 'Server license:')"
echo "$DEPOT_NAME 文件数: $(p4 -u admin files //$DEPOT_NAME/... 2>&1 | wc -l)"

# 触发 path-filter index
echo ""
echo "===== 触发 path-filter history index ====="
MARKER_DIR="/tmp/marker_$LOWERCASE"
mkdir -p "$MARKER_DIR"
echo "Migration completed at $(date)" > "$MARKER_DIR/.migrated"
chown -R perforce:perforce "$MARKER_DIR"

p4 -u admin client -i <<EOF >/dev/null
Client:	marker_$LOWERCASE
Owner:	admin
Root:	$MARKER_DIR
View:
	//$DEPOT_NAME/.migrated //marker_$LOWERCASE/.migrated
EOF

p4 -u admin -c marker_$LOWERCASE add "$MARKER_DIR/.migrated" 2>&1 | tail -1
p4 -u admin -c marker_$LOWERCASE submit -d "Migration marker" 2>&1 | tail -2

echo ""
echo "✅ $DEPOT_NAME 迁移完成"
SCRIPT_EOF

chmod +x /root/migrate_depot.sh
```

### 4e.4 批量迁移所有 depot

```bash
# Windows PowerShell: 批量上传
foreach ($depot in @("2025_CAFA_Game_Design","2025_Environment_Art_Class","...")) {
    $lower = $depot.ToLower()
    ssh root@192.168.1.241 "mkdir -p /opt/perforce/servers/master/$lower"
    scp -r "C:\path\to\$lower\*" root@192.168.1.241:/opt/perforce/servers/master/$lower/
}

# Ubuntu: 批量跑迁移脚本
for depot in 2025_CAFA_Game_Design 2025_Environment_Art_Class \
             2025_GameDesign_Class 2025_TA_Environment_Art_Class \
             2026_GameDesign_Class 2026_TA_Environment_Art_Class \
             MAXs_Instroctors MAXs_Portfolio_And_Career MAXs_SingleProject; do
    bash /root/migrate_depot.sh "$depot"
done
```

---

## 验证 + 测试

### 完整状态检查

```bash
echo "============================================================"
echo "P4D 完整状态检查"
echo "============================================================"
echo ""
echo "服务状态:    $(systemctl is-active p4d)"
echo "License:     $(p4 -u admin info | grep 'Server license:')"
echo "Counter:     $(p4 -u admin counter change)"
echo "Users:       $(p4 -u admin users | wc -l)"
echo "Groups:      $(p4 -u admin groups | wc -l)"
echo "Clients:     $(p4 -u admin clients | wc -l)"
echo "Depots:      $(p4 -u admin depots -a | wc -l)"
echo "Changelists: $(p4 -u admin changes | wc -l)"
echo ""
echo "===== Depots ====="
p4 -u admin depots -a
echo ""
echo "===== 最新 changelist ====="
p4 -u admin changes -m 3
```

### 多次重启稳定测试

```bash
for i in 1 2 3; do
    echo "===== 第 $i 次重启 ====="
    systemctl restart p4d
    sleep 10
    printf '!Gei181501\n' | p4 -u admin login >/dev/null 2>&1
    echo "Active:  $(systemctl is-active p4d)"
    echo "License: $(p4 -u admin info | grep 'Server license:')"
    echo "Counter: $(p4 -u admin counter change)"
done
```

### 客户端 sync 测试

```bash
mkdir -p /tmp/full_test
p4 -u admin client -i <<EOF
Client:	full_test
Owner:	admin
Root:	/tmp/full_test
View:
	//... //full_test/...
EOF

p4 -u admin -c full_test sync -m 10
ls /tmp/full_test/
p4 -u admin client -d full_test
rm -rf /tmp/full_test
```

---

## 紧急救援流程

### 服务器无法启动

```bash
# 1. 看 systemd 日志
journalctl -xeu p4d -n 50

# 2. 看 P4D 自己的日志
tail -50 /opt/perforce/servers/master/log

# 3. 试手动启动看具体报错
sudo -u perforce /opt/perforce/sbin/p4d \
    -r /opt/perforce/servers/master -p 1888 -L /opt/perforce/servers/master/log
# Ctrl+C 终止
```

### License 炸了

```bash
# 紧急救援(手动重置 counter)
systemctl stop p4d
echo "@pv@ 1 @db.counters@ @change@ @0@" > /tmp/p4_rescue.jnl
chown perforce:perforce /tmp/p4_rescue.jnl
sudo -u perforce /opt/perforce/sbin/p4d -r /opt/perforce/servers/master -jr /tmp/p4_rescue.jnl
systemctl start p4d
sleep 10
p4 -u admin info | grep "Server license:"
# 应该恢复 1000 users
```

### 完整回滚

如果迁移过程出问题需要回到某个备份点:

```bash
# 备份脚本(在改 db 之前先跑)
BACKUP=/root/db_backup_$(date +%Y%m%d-%H%M%S)
mkdir -p $BACKUP
systemctl stop p4d
cp /opt/perforce/servers/master/db.* $BACKUP/
cp /opt/perforce/servers/master/license $BACKUP/
cp /opt/perforce/servers/master/journal* $BACKUP/ 2>/dev/null
systemctl start p4d
echo "备份: $BACKUP"

# 回滚
systemctl stop p4d
rm /opt/perforce/servers/master/db.* /opt/perforce/servers/master/journal* 2>/dev/null
cp $BACKUP/* /opt/perforce/servers/master/
chown -R perforce:perforce /opt/perforce/servers/master/
systemctl start p4d
```

---

## 每日自动备份

```bash
mkdir -p /opt/perforce/backups
chown perforce:perforce /opt/perforce/backups

cat > /etc/cron.d/p4d-checkpoint <<'EOF'
# 每天 03:00 生成 checkpoint(同时压缩 + 轮转 journal)
0 3 * * * perforce /opt/perforce/sbin/p4d -r /opt/perforce/servers/master -jc -Z -p /opt/perforce/backups/checkpoint > /opt/perforce/backups/last.log 2>&1

# 每周日清理 30 天前的旧 checkpoint
0 4 * * 0 perforce find /opt/perforce/backups -name "checkpoint.*" -mtime +30 -delete
EOF

echo "✅ 每日 checkpoint 已配置(03:00)"
```

---

## 客户端使用指南

### 给学生发的连接说明

> **服务器**: `192.168.1.241:1888`
> **用户名**: 你原来的用户名(已恢复)
> **密码**: 联系 admin 重置
> **Workspace**: 不需要重新创建,你的老 workspace 名字会自动出现
>
> **看历史 changelist**:
> - 在 P4V 中点击右上角 **"Submitted"** 标签 (不是 "History" 标签)
> - 那里能看到所有人的全部提交历史
>
> **第一次连接后**:
> 如果你的本地文件是从老服务器 sync 下来的(还没 reconcile 过),先做一次 `Actions → Reconcile Offline Work` 让服务器认知到你的本地文件状态。

### P4V 已知行为

| 操作 | 行为 |
|------|------|
| 选 depot 看 **History** tab | 第一次显示空(直到该 depot 有 submit 触发索引)|
| 选 depot 看 **Submitted** tab | ✅ 显示全部 |
| 选具体文件看 History | 该文件第一次有 submit 后才工作 |
| 菜单 **View → Submitted Changelists** | ✅ 全局视图 |
| Sync / Edit / Submit | ✅ 全部正常 |

---

## 附录: 关键文件位置速查

```
/opt/perforce/
├── sbin/p4d                            # 服务器二进制
├── bin/p4                              # 客户端二进制
├── servers/master/                     # P4ROOT
│   ├── db.*                            # 数据库
│   ├── license                         # ⭐ License (千万别删)
│   ├── journal                         # 实时事务日志
│   └── log                             # P4D 运行日志
├── checkpoints/                        # 备份和迁移文件
│   ├── checkpoint.NNN                  # 完整 metadata 快照
│   └── ...各种 .jnl 文件               # 各种导入用 jnl
├── backups/                            # 每日自动备份
└── .p4_admin_passwd                    # admin 密码文件 (mode 600)

/etc/systemd/system/
├── p4d.service                         # 主 systemd unit
└── p4d.service.d/rescue.conf           # ⭐ 自动救援 hook

/tmp/
├── extract_p4_records.py               # Python 解析器
├── p4_rescue.jnl                       # systemd 用的 reset jnl
├── .p4tickets_admin                    # admin 的 P4 ticket
└── p4_post.log                         # ExecStartPost 日志(调试用)

/etc/cron.d/p4d-checkpoint              # 每日备份 cron
```

---

## 附录: 完整迁移顺序 checklist

```
□ Phase 0: 装 P4D 二进制
□ Phase 0: 创建 perforce 用户 + P4ROOT
□ Phase 0: -C1 -xi 初始化 case-insensitive 模式
□ Phase 1: 创建基础 systemd unit
□ Phase 1: 防火墙 + 环境变量
□ Phase 2: 把 license 文件放进 P4ROOT
□ Phase 2: 创建 admin 密码文件
□ Phase 2: ⭐ 配置 systemd 自动救援 hook
□ Phase 2: 启动 + 多次重启验证
□ Phase 3: 创建 admin 用户
□ Phase 3: 设密码 + super 权限
□ Phase 4a: 重建 depot 定义 (不要 replay db.depot)
□ Phase 4b: Replay user/group/protect
□ Phase 4c: 安装 Python 解析器
□ Phase 4c: Replay db.domain + db.view
□ Phase 4d: Replay db.change/desc/changex/etc (⚠️ 不要 db.counters)
□ Phase 4d: 重启验证 hook 设 counter=1543
□ Phase 4e: 对每个 depot:
   □ SCP 物理文件到全小写目录
   □ 修权限
   □ 提取 + replay db.rev/revcx/revdx/revhx
   □ Submit marker 文件激活 history index
□ 验证: 多次重启
□ 验证: 客户端 sync
□ 配置每日 checkpoint cron
□ 给学生发使用指南
```

---

## 文档更新记录

| 日期 | 内容 |
|------|------|
| 2026/04/28 | 初版 - 从单 depot 测试中总结的完整流程 |

---

**祝下次部署一气呵成,不再踩坑。**
