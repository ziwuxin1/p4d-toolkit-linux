<p align="center">
  <img src="assets/p4d-toolkit.png" alt="P4D Toolkit" width="160"/>
</p>

<h1 align="center">P4D Toolkit (Linux)</h1>

<p align="center">
  <b>One-click bash script for Perforce P4D disaster recovery, deployment, and self-healing on Ubuntu.</b><br/>
  <sub>Perforce P4D 灾难救援 / 部署 / 自动自愈一键脚本(Ubuntu / Debian)</sub>
</p>

<p align="center">
  <a href="https://github.com/ziwuxin1/p4d-toolkit-linux/stargazers"><img src="https://img.shields.io/github/stars/ziwuxin1/p4d-toolkit-linux?style=flat&logo=github&color=ff6b6b" alt="stars"/></a>
  <a href="https://github.com/ziwuxin1/p4d-toolkit-linux/issues"><img src="https://img.shields.io/github/issues/ziwuxin1/p4d-toolkit-linux?style=flat&color=red" alt="issues"/></a>
  <img src="https://img.shields.io/badge/shell-bash-1f425f?style=flat&logo=gnu-bash" alt="bash"/>
  <img src="https://img.shields.io/badge/Linux-Ubuntu_22.04+-E95420?style=flat&logo=ubuntu" alt="Ubuntu"/>
  <img src="https://img.shields.io/badge/P4D-2024.1-2EBC4F?style=flat" alt="P4D 2024.1"/>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/ziwuxin1/p4d-toolkit-linux?style=flat" alt="license"/></a>
</p>

<p align="center">
  <a href="#english">English</a> · <a href="#中文">中文</a>
</p>

---

<a id="english"></a>

## Quick start

One line, on any Ubuntu host:

```bash
curl -fsSL https://raw.githubusercontent.com/ziwuxin1/p4d-toolkit-linux/main/p4d-toolkit.sh -o p4d-toolkit.sh && sudo bash p4d-toolkit.sh
```

That drops you into a menu. Pick **5) one-shot full deploy** to install P4D, configure systemd self-healing hook, and schedule daily checkpoints — five minutes from blank Ubuntu to vaccinated production server.

## Overview

A menu-driven bash script that wraps every operation from the canonical [P4D-Migration-Complete-Guide.md](P4D-Migration-Complete-Guide.md) — install, license, systemd unit + boot-time auto-recovery hook, cron checkpoint, depot rsync, surgical recovery flows, health checks, uninstall.

Single file, ~700 lines. No dependencies beyond `p4d` / `p4` / `systemctl` / `bash`. Read-only by default; every destructive operation snapshots `db.*` first and writes a JSON-line audit log to `/var/log/p4d-toolkit.log`.

## Features

```
── Deployment ────────────────────────
1) Install P4D 2024.1
2) Install license file
3) Configure systemd + boot-time self-healing hook   (the "vaccine")
4) Configure daily 03:00 checkpoint cron + rsync
5) One-shot full deploy (1→2→3→4)

── Rescue ───────────────────────────
6) Counter Rescue (when license has degraded to 5-user mode)
7) One-click Restore (latest checkpoint + journals + counter reset)

── Health & Status ──────────────────
10) Health check (service / port / license / counter / backup / disk / journal)
11) Backup status
12) systemd journal

── Maintenance ──────────────────────
13) Take a checkpoint now
14) Run depot rsync now
15/16/17) Start / Stop / Restart service

── Danger zone ──────────────────────
99) Uninstall P4D + Toolkit (preserves database)
```

### What the boot-time vaccine does

The `ExecStartPre` / `ExecStartPost` systemd hooks installed by option 3 mirror Phase 2.4 of the migration guide verbatim:

```
ExecStartPre  → inject @pv@ 1 @db.counters@ @change@ @0@ → license validation passes
ExecStartPost → log in admin → query MAX(change) → set counter = MAX+1
```

Result: no matter what state your `db.counters.change` ended up in (e.g. after a checkpoint replay, a rehosted license, or a weird crash), P4D **always** starts cleanly on every reboot. The counter automatically tracks growing change numbers — never needs manual intervention.

## Non-interactive subcommands

For cron, CI, or remote SSH automation:

```bash
sudo bash p4d-toolkit.sh status          # health check
sudo bash p4d-toolkit.sh checkpoint      # take a checkpoint now
sudo bash p4d-toolkit.sh rsync           # run depot rsync now
sudo bash p4d-toolkit.sh counter-rescue  # one-click counter rescue
sudo bash p4d-toolkit.sh restore         # one-click restore from backup
```

## Configuration

Defaults live in `/etc/p4d-toolkit.conf` (auto-generated on first deploy). Override via env vars on any invocation:

```bash
sudo P4ROOT=/srv/p4d P4PORT=2666 BACKUP_DIR=/mnt/external/backups bash p4d-toolkit.sh
```

| Variable | Default |
|---|---|
| `P4D_VERSION` | `2024.1` |
| `P4ROOT` | `/opt/perforce/servers/master` |
| `P4PORT` | `1888` |
| `P4D_USER` | `perforce` |
| `BACKUP_DIR` | `/opt/perforce/backups` (checkpoint + journal landing) |
| `DEPOT_BACKUP_DIR` | `/mnt/backup/depots` (rsync target — must be writable) |

## Pitfalls this script defuses

The migration guide documents nine real-world incidents. The script wraps automation around all of them:

| # | Pitfall | Defence |
|---|---|---|
| 1 | License + counter coupling — high counter causes service to refuse start | Boot-time `ExecStartPre/Post` vaccine + Counter Rescue option |
| 2 | Replaying full `db.counters` from checkpoint corrupts license validation | One-click Restore explicitly injects counter-reset journal pre-start |
| 3 | Depot directory case sensitivity (Linux is case-sensitive) | Setup writes lowercase canonical paths in systemd unit |
| 4 | Multi-line `@…@` fields in journal can't be grep-extracted | Selective restore (when implemented) uses proper P4-journal stream parser |
| 5 | Path-filtered history needs a submit to activate | Path-filter activator (planned, manual workaround documented in guide) |
| 6 | License must be at `$P4ROOT/license` | Setup verifies + warns on IP mismatch |
| 7 | perforce user can't read root home | Setup uses `/opt/perforce/checkpoints/` as scratch |
| 8 | Special characters in passwords break systemd `ExecStartPost` | Password stored in mode-600 file, `<` redirected into login |
| 9 | `P4TICKETS` default path is unwritable | `ExecStartPost` exports `P4TICKETS=/tmp/.p4tickets_admin` |

## Companion: Windows Version

There's a Windows GUI counterpart with the same recovery algorithms (one-click recovery, selective table restore, counter rescue, boot-time vaccine, 360-style health-check ring). It's currently in a private repo. Contact for access if you need it.

## License

[MIT](LICENSE)

---

<a id="中文"></a>

## 快速开始

任何 Ubuntu 主机一行搞定:

```bash
curl -fsSL https://raw.githubusercontent.com/ziwuxin1/p4d-toolkit-linux/main/p4d-toolkit.sh -o p4d-toolkit.sh && sudo bash p4d-toolkit.sh
```

进菜单后选 **5)一次性全部部署** — 装 P4D + 配 systemd 启动自愈 hook + 配每日 checkpoint。空白 Ubuntu 到接种疫苗的生产服务器,5 分钟。

## 项目简介

菜单驱动的 bash 脚本,把 [P4D-Migration-Complete-Guide.md](P4D-Migration-Complete-Guide.md) 里的所有操作都封装好 — 安装 / license / systemd unit + 开机自愈 hook / cron checkpoint / depot rsync / 表级精准恢复 / 健康体检 / 卸载。

单文件约 700 行。只依赖 `p4d` / `p4` / `systemctl` / `bash`。默认只读,任何破坏性操作都先快照 `db.*`,操作落地到 `/var/log/p4d-toolkit.log`(JSON-line 审计日志)。

## 功能

```
── 部署 ────────────────────────────
1) 全新安装 P4D 2024.1
2) 装 license 文件
3) 配 systemd + 启动自愈 hook(疫苗)
4) 配每日 03:00 checkpoint cron + rsync
5) 一次性全部部署(1→2→3→4)

── 救援 ────────────────────────────
6) Counter 救援(license 被错降到 5 用户时)
7) 一键恢复(最新 checkpoint + journals + counter 重置)

── 体检 / 状态 ────────────────────
10) 健康体检(服务 / 端口 / license / counter / 备份 / 磁盘 / journal 错误数)
11) 备份状态
12) systemd journal

── 维护 ────────────────────────────
13) 立刻生成 checkpoint
14) 立刻 rsync depot
15/16/17) 启动 / 停止 / 重启 服务

── 危险区 ─────────────────────────
99) 卸载 P4D + Toolkit(数据库会保留)
```

### 启动自愈疫苗做了什么

选项 3 装的 `ExecStartPre` / `ExecStartPost` systemd hook 是指南 Phase 2.4 的逐字实现:

```
ExecStartPre  → 注入 @pv@ 1 @db.counters@ @change@ @0@ → license 校验过
ExecStartPost → admin 登录 → 读 MAX(change) → 设 counter = MAX+1
```

结果:无论你的 `db.counters.change` 怎么炸(checkpoint 还原 / license rehost / 异常崩溃),P4D **永远**能在每次重启后干净起来。counter 会自动跟随 changelist 增长,**永不需要人工干预**。

## 非交互子命令

适合 cron / CI / 远程 SSH 自动化:

```bash
sudo bash p4d-toolkit.sh status          # 健康体检
sudo bash p4d-toolkit.sh checkpoint      # 立刻 checkpoint
sudo bash p4d-toolkit.sh rsync           # 立刻 rsync
sudo bash p4d-toolkit.sh counter-rescue  # Counter 救援
sudo bash p4d-toolkit.sh restore         # 一键恢复
```

## 配置

默认值在 `/etc/p4d-toolkit.conf`(部署时自动生成)。环境变量临时覆盖:

```bash
sudo P4ROOT=/srv/p4d P4PORT=2666 BACKUP_DIR=/mnt/external/backups bash p4d-toolkit.sh
```

| 变量 | 默认值 |
|---|---|
| `P4D_VERSION` | `2024.1` |
| `P4ROOT` | `/opt/perforce/servers/master` |
| `P4PORT` | `1888` |
| `P4D_USER` | `perforce` |
| `BACKUP_DIR` | `/opt/perforce/backups`(checkpoint + journal 落地) |
| `DEPOT_BACKUP_DIR` | `/mnt/backup/depots`(rsync 目标 — 必须可写) |

## 针对的 9 个真实坑

迁移指南记录了 9 个真实事故。这个脚本对所有这些做了自动化包装:

| # | 坑 | 防御 |
|---|---|---|
| 1 | License + counter 耦合,高 counter 让服务拒启 | 启动自愈疫苗 + Counter 救援 |
| 2 | 从 checkpoint replay 完整 db.counters 会炸 license | 一键恢复显式启动前注入 reset jnl |
| 3 | depot 目录大小写敏感(Linux 文件系统) | 部署时把 systemd unit 里写小写规范化路径 |
| 4 | Journal 多行 `@…@` 字段不能 grep 提取 | 表级精准恢复(规划中)用流式 P4-journal parser |
| 5 | Path-filtered history 需要 submit 触发 | Path-Filter 激活(规划中,指南记载手动方案) |
| 6 | License 必须放 `$P4ROOT/license` | 部署时验证 + IP 不匹配警告 |
| 7 | perforce 用户读不到 root 家目录 | 部署用 `/opt/perforce/checkpoints/` 中转 |
| 8 | 密码含特殊字符破坏 systemd `ExecStartPost` | 密码存 mode-600 文件,`<` 重定向登录 |
| 9 | `P4TICKETS` 默认路径不可写 | `ExecStartPost` 显式 export `P4TICKETS=/tmp/.p4tickets_admin` |

## 配套:Windows 版本

有一个 Windows GUI 版本带同样的救援算法(一键恢复 / 表级精准恢复 / Counter 救援 / 启动自愈疫苗 / 360 风格健康体检环)。私有仓库,需要用请联系作者。

## 许可

[MIT](LICENSE)
