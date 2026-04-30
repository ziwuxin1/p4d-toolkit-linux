# P4D Windows → Linux 完整迁移指南

> 本文档基于一次真实的双 master(MAXs + Student)从 Windows 迁移到 Ubuntu Linux 的实战记录。
> 包含每一步可复制的命令、踩到的所有坑、对应的修复 commit。

---

## 目录

- [概述](#概述)
- [前置准备](#前置准备)
- [Phase 1 — Ubuntu master 部署](#phase-1--ubuntu-master-部署)
- [Phase 2 — depot 物理文件传输](#phase-2--depot-物理文件传输)
- [Phase 3 — 元数据恢复(一键恢复)](#phase-3--元数据恢复一键恢复)
- [Phase 4 — NAS 双副本备份](#phase-4--nas-双副本备份)
- [Phase 5 — 公网暴露](#phase-5--公网暴露)
- [日常运维](#日常运维)
- [灾难恢复](#灾难恢复)
- [踩过的所有坑](#踩过的所有坑)
- [FAQ](#faq)

---

## 概述

### 适用场景

- 把现有 Windows P4D 服务器迁移到 Ubuntu Linux
- P4D 数据规模 100GB ~ 数 TB 物理文件
- 需要灾备(本地 + NAS 双副本)
- 跨平台 case 兼容(Windows -C1 → Linux -C1)

### 总体架构

```
旧 Windows P4D ──┐
                 ├─→ checkpoint + journal ──→ Linux master(metadata 恢复)
                 └─→ Root Files (depot 物理文件) ──robocopy──→ Linux master P4ROOT

Linux master ──cron──→ 本地 checkpoint(14 天) ──rsync──→ NAS(90 天)
```

### 时间预算

| 阶段 | 时间 |
|------|------|
| Ubuntu 部署 + toolkit 跑通 | 30 分钟 |
| robocopy 1TB 物理文件 | 1-3 小时(取决于网速) |
| 元数据 replay | 5-15 分钟 |
| NAS NFS 配置 + 首次推送 | 1-2 小时 |
| 全量 verify(可选) | 30-60 分钟 |
| **合计** | **半天到一天** |

---

## 前置准备

### 旧 Windows P4D 端

在迁移之前**生成最新 checkpoint**:

```cmd
# 老 P4D 还能跑的话
p4 admin checkpoint
```

会在 P4ROOT 同级目录生成:
- `checkpoint.NNN` — 元数据快照
- `checkpoint.NNN.md5` — 校验和
- `journal.NNN-1` — 上一段 live journal(已轮转)

如果 checkpoint 之后还有变更(学生还在提交),把当前 P4ROOT 下的 `journal` 文件(无后缀)也拿过来,这是 live journal。

### 准备的文件清单

待会儿要上传到 Linux 的:
- ✅ `checkpoint.NNN` + `checkpoint.NNN.md5` — 放 Root_Temp
- ✅ `journal`(live, 无后缀)— 放 Root_Temp(可选,checkpoint 之后无变更可省)
- ✅ `license` 文件 — 放 Install_Temp
- ✅ `Root Files\` 整个目录(depot 物理文件)— robocopy 推送

### Ubuntu 主机要求

- Ubuntu 22.04 / 24.04 LTS
- 磁盘空间 ≥ depot 总大小 × 1.5 (临时空间 + checkpoint 缓冲)
- root SSH 访问
- 静态局域网 IP(DHCP 静态绑定也行)

### Ubuntu 怎么装?跟视频走

如果你还没装好 Ubuntu,直接看这两个视频:

| 视频 | 内容 |
|------|------|
| 📺 [PVE 9.0 系统安装与初始化全攻略](https://youtu.be/hzkM0bycv4A) | PVE 虚拟化平台装好 |
| 📺 [手把手 PVE 安装 Ubuntu Server 24,配置 SSH 登录+Docker 环境](https://youtu.be/xa5iCt0OY5w) | PVE 上开 Ubuntu Server 24 |

---

## Phase 1 — Ubuntu master 部署

### 1.1 (可选) 自定义端口/路径

如果你想跑非默认端口/路径,先写配置:

```bash
sudo tee /etc/ssh-toolkit.conf <<'EOF'
P4PORT="1888"
P4ROOT="/opt/perforce/servers/master"
EOF
```

不写就用 toolkit 默认: `P4PORT=1888`, `P4ROOT=/opt/perforce/servers/master`。

### 1.2 一键拉脚本 + 跑

```bash
curl -fsSL https://raw.githubusercontent.com/ziwuxin1/ssh-toolkit-linux/main/src/linux/install/ssh-toolkit.sh -o ssh-toolkit.sh
sudo bash ssh-toolkit.sh
```

### 1.3 按菜单顺序操作

```
菜单 0 → 创建工作目录 + 下载 P4D 安装包
菜单 1 → 全新安装 P4D 2024.1
菜单 2 → 安装 license 文件
菜单 3 → 配置 systemd + 启动自愈 hook
菜单 4 → 配置每日 03:00 checkpoint cron + NAS 推送
```

或者一键: **菜单 5(一次性全部部署)**。

### 1.4 准备外部文件

跑菜单 0 之后会创建 `/root/P4_Temp/{Install_Temp, Root_Temp}`。手动放进去:

```bash
# 在 Windows 上传过来后:
ls /root/P4_Temp/Install_Temp/
# license

ls /root/P4_Temp/Root_Temp/
# checkpoint.151
# checkpoint.151.md5
# journal           ← 可选,如果有 live journal 变更
```

### 1.5 验证部署

```bash
sudo systemctl status p4d --no-pager | head -5
# 应该看到 active (running)

sudo /opt/perforce/bin/p4 -p localhost:1888 info
# 应该看到 Server license: 你的 license
```

---

## Phase 2 — depot 物理文件传输

把 Windows 上的 `Root Files\` 目录推到 Linux P4ROOT。**robocopy 走 SMB 比 scp 快 10 倍**。

### 2.1 Linux 端开 Samba (临时)

```bash
sudo systemctl stop p4d  # 推之前停 P4D,避免空 db.* 状态干扰

sudo apt update && sudo apt install -y samba
sudo smbpasswd -a perforce  # 设 SMB 密码,传完就删

sudo tee -a /etc/samba/smb.conf > /dev/null <<'EOF'

[p4root]
    path = /opt/perforce/servers/master
    browseable = yes
    writable = yes
    valid users = perforce
    create mask = 0644
    directory mask = 0755
    force user = perforce
    force group = perforce
EOF

sudo systemctl restart smbd nmbd
sudo ufw allow from 192.168.1.0/24 to any port 445 proto tcp 2>/dev/null
sudo ufw allow from 192.168.1.0/24 to any port 139 proto tcp 2>/dev/null
```

### 2.2 Windows 端 PowerShell(管理员)

```powershell
$linuxIP = "192.168.1.51"  # 改成你 Linux master 的 IP

# 测端口
Test-NetConnection -ComputerName $linuxIP -Port 445

# 挂载
net use \\$linuxIP\p4root /user:perforce
# 输入 SMB 密码

# 测能写
ls \\$linuxIP\p4root\
"test" | Out-File \\$linuxIP\p4root\_writetest.txt
del \\$linuxIP\p4root\_writetest.txt
```

### 2.3 准备源目录

⚠️ **关键**: 源目录里**只能有 depot 文件夹,不能有 checkpoint/journal**。

```powershell
# 检查源目录
ls "I:\YourPath\Root Files\" | Where-Object { $_.Name -match 'checkpoint|journal' }
```

如果有,要么移走,要么 robocopy 加 `/XF "checkpoint.*" "journal"` 排除。

### 2.4 跑 robocopy

```powershell
$src = "I:\YourPath\Root Files"
$dst = "\\192.168.1.51\p4root"
$logFile = "C:\p4-transfer.log"

# 预览(秒级)
robocopy $src $dst /E /MT:32 /COPY:DAT /XA:H /NFL /NDL /L | Select-String "Bytes :|Files :|Dirs :"

# 实跑
robocopy $src $dst /E /MT:32 /Z /R:3 /W:5 /COPY:DAT /XA:H /NFL /NDL /TEE /ETA /LOG:$logFile
```

参数说明:

| 参数 | 作用 |
|------|------|
| `/E` | 包括空目录在内全部递归 |
| `/MT:32` | 32 线程并行 |
| `/Z` | 重启模式(支持续传) |
| `/COPY:DAT` | 只拷数据/属性/时间戳,不拷 ACL |
| `/XA:H` | 跳过隐藏文件 |

### 2.5 完成后改所有者

```bash
sudo chown -R perforce:perforce /opt/perforce/servers/master/
sudo chmod -R u+rwX,go+rX /opt/perforce/servers/master/

# 验证大小
du -sh /opt/perforce/servers/master/
du -sh /opt/perforce/servers/master/*/ | head -20
```

### 2.6 关掉 Samba (传完就关)

```bash
sudo systemctl stop smbd nmbd
sudo systemctl disable smbd nmbd
sudo sed -i '/^\[p4root\]/,/^$/d' /etc/samba/smb.conf
sudo apt remove --purge -y samba samba-common
sudo apt autoremove -y
sudo ufw delete allow from 192.168.1.0/24 to any port 445 proto tcp 2>/dev/null
sudo ufw delete allow from 192.168.1.0/24 to any port 139 proto tcp 2>/dev/null
```

Windows 端:
```powershell
net use \\192.168.1.51\p4root /delete
```

---

## Phase 3 — 元数据恢复(一键恢复)

### 3.1 跑菜单 7

```bash
sudo bash ~/ssh-toolkit.sh
# 选 7
# 输入 CONFIRM
```

新版脚本会自动:

1. ✅ 检测 perforce 用户读不到 /root → 自动 stage 到 /opt/perforce/backups
2. ✅ 拾起无后缀 live journal
3. ✅ peek checkpoint 头部 64MB 自动检测 case 模式
4. ✅ replay 失败时自动 -C1 重试
5. ✅ 启动后自愈 counter

### 3.2 预期输出

```
🚀 一键恢复
ℹ 来源目录: /root/P4_Temp/Root_Temp
继续? y
输入 CONFIRM 继续: CONFIRM
⚠ perforce 用户读不到 /root/P4_Temp/Root_Temp,自动 stage 到 /opt/perforce/backups
✓ 已 stage 3 个文件到 /opt/perforce/backups
ℹ 最新 checkpoint: /opt/perforce/backups/checkpoint.151 (#151)
ℹ 检测到 live journal: /opt/perforce/backups/journal (最后 replay)
ℹ 需要 replay 的 journal 数: 1
ℹ 检测 checkpoint case 模式...
ℹ Checkpoint 声明 case 模式: -C1 (Windows hybrid)
ℹ Replay /opt/perforce/backups/checkpoint.151 -C1
ℹ Replay /opt/perforce/backups/journal
ℹ 注入 counter=0 jnl
ℹ 启动服务
ℹ Counter 校准: 74 (基于 MAX 73)
```

### 3.3 验证恢复成功

```bash
sudo systemctl status p4d --no-pager | head -5

sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin login < /opt/perforce/.p4_admin_passwd

# 关键检查
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin info | grep -iE 'license|case|version'
# Server license: ...     ← license 没炸
# Case Handling: insensitive   ← Windows 兼容模式

# depot 列表
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin depots
# 应该看到所有 depot

# 用户和 changelist
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin users | wc -l
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin changes -m 5
```

### 3.4 (可选) 全量 verify

```bash
# 后台跑(30-60 分钟)
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin verify -q //... 2>&1 | tee /tmp/verify.log &

# 完事看结果
grep -c 'MISSING!' /tmp/verify.log
grep -c 'BAD!' /tmp/verify.log
```

⚠️ **已知问题**: 中文路径文件名因 Windows GBK ↔ Linux UTF-8 编码差异**会丢失**,这是 Perforce 跨平台老问题,目前没好的自动方案。受影响学生需要重新提交。

---

## Phase 4 — NAS 双副本备份

### 4.1 群晖端配置 (DSM 7.x)

#### 4.1.1 启用 NFS 服务
```
控制面板 → 文件服务 → NFS →
☑ 启用 NFS 服务
NFS 最高版本: NFSv4.1
```

#### 4.1.2 给共享文件夹设 NFS 权限
```
控制面板 → 共享文件夹 → 选你的备份目录 → 编辑 → NFS 权限 → 新增

服务器 IP: 192.168.1.51 (你 Linux master 的 IP)
权限: 读写
Squash: 将所有用户映射到 admin   ← 关键!
☑ 启用异步
```

#### 4.1.3 给 admin 用户开共享访问
```
同一对话框 → 权限 标签 →
admin → 取消"禁止访问" + 勾"可读写" → 保存
```

⚠️ **必须两个都做**,缺一个会 Permission denied。

### 4.2 Linux 端挂载

```bash
sudo apt install -y nfs-common

NAS_IP="192.168.1.230"
NAS_PATH="/volume1/P4D-MAXs"  # 你 NAS 上的实际路径
sudo mkdir -p /mnt/nas/p4d-backups/vm1

# 测试挂载
sudo mount -t nfs4 ${NAS_IP}:${NAS_PATH} /mnt/nas/p4d-backups/vm1
df -h /mnt/nas/p4d-backups/vm1

# 测能写
sudo -u perforce touch /mnt/nas/p4d-backups/vm1/_writetest && \
  ls -la /mnt/nas/p4d-backups/vm1/_writetest && \
  sudo rm /mnt/nas/p4d-backups/vm1/_writetest

# fstab 持久化
echo "${NAS_IP}:${NAS_PATH} /mnt/nas/p4d-backups/vm1 nfs4 rw,async,_netdev,noatime,nofail 0 0" | sudo tee -a /etc/fstab
sudo mount -a
```

### 4.3 触发首次 rsync

```bash
sudo bash ~/ssh-toolkit.sh
# 选 14
```

第一次推全量(几百 GB),开第二个 SSH 窗口看进度:

```bash
watch -n 30 'du -sh /mnt/nas/p4d-backups/vm1/depots/'
```

### 4.4 重跑菜单 4 让 cron 用新版 rsync

```bash
sudo bash ~/ssh-toolkit.sh
# 选 4
```

之后每天:
- **03:00** 本地 checkpoint
- **03:30** rsync checkpoint+journal 到 NAS
- **04:00** rsync depot 到 NAS (增量,分钟级)

---

## Phase 5 — 公网暴露

### 5.1 路由器端口映射

| 字段 | 推荐值 |
|------|------|
| 协议 | TCP |
| 内部 IP | Linux master 的局域网 IP |
| 内部端口 | 1888 (P4D 实际监听) |
| **外部端口** | **28888** (不要 1888,避免扫描) |

### 5.2 公网测试

```powershell
# 用 4G/移动数据(不在你家 WiFi)测
Test-NetConnection -ComputerName 你家公网IP -Port 28888
```

### 5.3 (强烈推荐) 启用 SSL

公网传输不加密 = 学生密码可被嗅探。

```bash
sudo systemctl stop p4d
sudo -u perforce /opt/perforce/sbin/p4d -r /opt/perforce/servers/master -Gc

sudo systemctl edit p4d
```

加:
```ini
[Service]
Environment=P4PORT=ssl:1888
```

```bash
sudo systemctl start p4d
```

学生连接改成 `ssl:你家公网IP:28888`,首次会问"信任服务器指纹",`p4 trust -y` 确认。

### 5.4 (可选) 跨境加速 — 腾讯云 P4P 双层中转

```
中国学生 → 腾讯云国内 P4P (上海/广州) → 腾讯云海外 P4P (香港) → 你家 master
```

关键点:
- 两台 ECS 在同一个 CCN(云联网)里,中间走专线
- P4P 缓存文件,后续 sync 直接命中
- 学生只改 `P4PORT` 就能用,workspace 不用动

---

## 日常运维

### 健康体检

```bash
sudo bash ~/ssh-toolkit.sh
# 主菜单顶部自动显示
```

每次刷新菜单都会跑一遍,直观看到:
- 服务运行状态
- 端口监听
- License 状态
- Counter 一致性
- 本地/NAS checkpoint 新鲜度
- 磁盘空间

### 看 cron 跑得对不对

```bash
# cron 配置
cat /etc/cron.d/p4d-backup

# 上次 rsync 输出
cat /mnt/nas/p4d-backups/vm1/checkpoints/last-rsync.log
cat /mnt/nas/p4d-backups/vm1/depots/last-rsync.log

# systemd journal
sudo journalctl -u p4d -n 50 --no-pager
```

### 手动触发备份

```bash
sudo bash ~/ssh-toolkit.sh

# 13: 立刻生成 checkpoint
# 14: 立刻 rsync 到 NAS
```

### 服务管理

```bash
# 通过 toolkit
sudo bash ~/ssh-toolkit.sh
# 15: 启动
# 16: 停止
# 17: 重启

# 或者直接 systemd
sudo systemctl start/stop/restart p4d
```

---

## 灾难恢复

### 场景 1: master 整个挂了,从 NAS 恢复到新机器

1. 在新 Ubuntu 上跑 toolkit,菜单 5 一次性部署(1→2→3→4)
2. 把 NAS 上的内容拉回来:
   ```bash
   sudo cp /mnt/nas/p4d-backups/vm1/checkpoints/checkpoint.NNN /root/P4_Temp/Root_Temp/
   sudo cp /mnt/nas/p4d-backups/vm1/checkpoints/checkpoint.NNN.md5 /root/P4_Temp/Root_Temp/
   sudo cp /mnt/nas/p4d-backups/vm1/checkpoints/journal /root/P4_Temp/Root_Temp/  # live journal,如果有
   
   # depot 物理文件
   sudo rsync -av /mnt/nas/p4d-backups/vm1/depots/ /opt/perforce/servers/master/
   sudo chown -R perforce:perforce /opt/perforce/servers/master/
   ```
3. 跑菜单 7 一键恢复元数据
4. 验证 license + depot + 用户都在

### 场景 2: counter 漂移 (license 突然变 5-user)

```bash
sudo bash ~/ssh-toolkit.sh
# 选 6: Counter 救援
```

或者直接 systemd 重启,自愈 hook 会自动修。

### 场景 3: db.* 损坏但 depot 完好

```bash
sudo systemctl stop p4d
sudo find /opt/perforce/servers/master -maxdepth 1 -name "db.*" -delete

# 用最新 checkpoint replay
sudo bash ~/ssh-toolkit.sh
# 选 7
```

---

## 踩过的所有坑

### 坑 1: 健康体检让脚本崩 (commit `7eb24df`)

**症状**: 全新机器上跑脚本,菜单还没出来就退出。

**原因**: `df -P "$P4ROOT"` 在 P4ROOT 不存在时返回非 0,触发 errexit。

**修复**: 健康体检函数体放进子 shell,内部 `set +e`。

### 坑 2: 自定义端口 systemd hook 不跟 (commit `16b2409`)

**症状**: 设 `P4PORT=2666`,P4D 监听 2666,但 systemd 自愈 hook 仍连 1888。

**原因**: dropin 文件用 `<<'EOF'` literal heredoc,1888 写死。

**修复**: 用占位符 + sed 替换。

### 坑 3: live journal 不被识别 (commit `96df731`)

**症状**: Root_Temp 里放了 checkpoint.NNN + 无后缀 journal,菜单 7 报"需要 replay 的 journal 数: 0"。

**原因**: `journal.[0-9]*` 不匹配无后缀 `journal`。

**修复**: 收集编号 journal 后,追加无后缀 live journal。

### 坑 4: /root 权限隔离 (commit `a6ef457`)

**症状**: 菜单 7 报 `/root/P4_Temp/Root_Temp/checkpoint.NNN: Permission denied`。

**原因**: `/root` 默认 700,perforce 用户进不去。

**修复**: 自动 stage 到 `/opt/perforce/backups`(perforce 一定能读)。

### 坑 5: case 模式 mismatch (commit `a020db3`, `435692f`)

**症状**: replay 失败 "Case-handling mismatch: server uses Unix-style (-C0) but journal flags are Windows-style (-C1)!"

**原因**: Windows P4D 默认 -C1, Linux 默认 -C0,db 创建时 case 模式锁定。

**修复**:
1. 自动 peek checkpoint 头部找 `@case@` 字段
2. 检测窗口扩到 64MB,失败则全文件扫描
3. 兜底: replay 失败时自动 -C1 重试

### 坑 6: ExecStop 失败 (commit `ec69dc6`)

**症状**: `systemctl restart p4d` 报 `Access for user 'perforce' has not been enabled by 'p4 protect'`,服务标记 failed。

**原因**: ExecStop 跑 `p4 admin stop`,默认用 systemd User= 即 perforce,protect 表里 perforce 不是 super。

**修复**: 改成 admin login → admin stop,失败 SIGTERM 兜底。

### 坑 7: svc_state 误报 (commit `4acb412`)

**症状**: banner 显示 "Service: 未安装" 但服务实际在跑。

**原因**: `systemctl list-unit-files | grep` 在某些版本输出格式不同。

**修复**: 改用 `systemctl cat`,跨版本稳定。

### 坑 8: rsync 兼容 NFS squash (commit `a75e2f1`)

**症状**: rsync 退出码 23,errexit 让 [2/2] depot 不跑。

**原因**: NFS all_squash 拒绝 chown,rsync 想保留 owner/group/perms 失败。

**修复**: 加 `--no-owner --no-group --no-perms`。

### 坑 9: 中文路径文件丢失 (Perforce 跨平台老问题)

**症状**: verify 报大量 MISSING!,路径里全是 `▒` 乱码。

**原因**: Windows P4D 用 GBK 存中文文件名,Linux 期望 UTF-8。db.* 里的字节串和 Linux 文件系统对不上。

**解决**: 要么老 master 提前升级到 unicode 模式重生成 checkpoint,要么接受这部分丢失。

---

## FAQ

### Q: 端口可以改吗?会炸 license 吗?

可以改,不会炸 license。Perforce license 不绑定端口。

### Q: 用 1666 还是 1888?

Toolkit 默认 1888。**避开 1666**(Perforce 标准端口,公网扫描机器人会扫)。

### Q: 学生 client spec 要改吗?

只改 `P4PORT`(IP 和端口),其他不变。`View:` 路径在 db 里,不在客户端。

### Q: rsync 的 cron 几点跑?能改吗?

默认 `03:00` checkpoint, `03:30` rsync checkpoint, `04:00` rsync depot。改的话编辑 `/etc/cron.d/p4d-backup`。

### Q: NAS 满了怎么办?

`保留 90 天` 是 toolkit 的设计目标,但**实际删除逻辑没写**。NAS 上需要你自己设保留策略,或者手动清旧 checkpoint。

### Q: 公网暴露安全吗?

**不直接暴露**。建议:
1. 用腾讯云中转(学生连云端,你家 IP 不暴露)
2. 路由器映射用非标端口(如 28888)
3. 启用 SSL
4. 装 fail2ban 防爆破

### Q: live journal 比 checkpoint 大几个 GB 是不是异常?

不一定。学生持续提交期间 live journal 会涨。每天 03:00 checkpoint 时会自动轮转,大小归零。

---

## 附录: toolkit 一键命令速查

```bash
# 拉脚本
curl -fsSL https://raw.githubusercontent.com/ziwuxin1/ssh-toolkit-linux/main/src/linux/install/ssh-toolkit.sh -o ssh-toolkit.sh

# 进菜单
sudo bash ssh-toolkit.sh

# 非交互命令
sudo bash ssh-toolkit.sh status        # 健康体检
sudo bash ssh-toolkit.sh checkpoint    # 立刻 checkpoint
sudo bash ssh-toolkit.sh rsync         # 立刻 rsync 到 NAS
sudo bash ssh-toolkit.sh restore       # 一键恢复
sudo bash ssh-toolkit.sh counter-rescue  # counter 救援
```

## 附录: 关键路径速查

| 路径 | 用途 |
|------|------|
| `/opt/perforce/servers/master/` | P4ROOT (db.* + depot 物理文件) |
| `/opt/perforce/backups/` | 本地 checkpoint(保留 14 天) |
| `/opt/perforce/.p4_admin_passwd` | admin 密码文件(systemd hook 用) |
| `/etc/systemd/system/p4d.service` | systemd unit |
| `/etc/systemd/system/p4d.service.d/rescue.conf` | 自愈 hook(ExecStartPre/Post) |
| `/etc/cron.d/p4d-backup` | 每日备份 cron |
| `/etc/ssh-toolkit.conf` | toolkit 配置(P4PORT/P4ROOT 等) |
| `/var/log/ssh-toolkit.log` | toolkit 操作日志 |
| `/mnt/nas/p4d-backups/vm1/` | NAS 双副本(checkpoints + depots) |
| `/root/P4_Temp/Install_Temp/` | 安装临时区(license + tgz) |
| `/root/P4_Temp/Root_Temp/` | 恢复临时区(checkpoint + journal) |

---

*最后更新: 2026-04-30 — 基于 MAXs + Student 双 master 实战迁移*
