<h1 align="center">SSH Toolkit (Linux)</h1>

<p align="center">
  <b>One-click bash script for Linux server deployment, rescue, and self-heal.</b><br/>
  <sub>Linux 服务器一键运维脚本 — 部署 / 救援 / 自动自愈(Ubuntu)</sub>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/shell-bash-1f425f?style=flat&logo=gnu-bash" alt="bash"/>
  <img src="https://img.shields.io/badge/Linux-Ubuntu_22.04+-E95420?style=flat&logo=ubuntu" alt="Ubuntu"/>
  <a href="LICENSE"><img src="https://img.shields.io/badge/%E6%8E%88%E6%9D%83-MIT-blue?style=flat" alt="授权"/></a>
</p>

---

## Quick start / 快速开始

```bash
curl -fsSL https://raw.githubusercontent.com/ziwuxin1/ssh-toolkit-linux/main/src/linux/install/ssh-toolkit.sh -o ssh-toolkit.sh && sudo bash ssh-toolkit.sh
```

进菜单后选 **5)一次性全部部署** — 5 分钟从空白 Ubuntu 到生产就绪。

## Menu / 菜单

```
── 部署 ──
1) 安装服务
2) 装 授权 文件
3) 配 systemd + 启动自愈 hook
4) 配每日 03:00 checkpoint cron + rsync
5) 一次性全部部署

── 救援 ──
6) Counter 救援
7) 一键恢复

── 体检 ──
10) 健康体检
11) 备份状态
12) systemd journal

── 维护 ──
13) 立刻 checkpoint
14) 立刻 rsync
15/16/17) 启 / 停 / 重启 服务

── 卸载 ──
99) Uninstall(数据库保留)
```

## 授权

[MIT](LICENSE)
