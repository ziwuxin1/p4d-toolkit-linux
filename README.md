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

**菜单选项 0** 会自动:
- 创建工作目录 `/root/P4_Temp/{Install_Temp, Root_Temp}`
- 从 GitHub 下载 server tgz 到 `Install_Temp/`

之后**手动**准备:
- `license` 文件 → 放到 `/root/P4_Temp/Install_Temp/license`
- 迁移数据(depot 物理文件 / checkpoint / journal)→ 放到 `/root/P4_Temp/Root_Temp/`

都准备好后选 **5)一次性全部部署** 一气呵成。

## Menu / 菜单

```
── 准备 ──
0) 一键创建工作目录 + 下载安装包

── 部署 ──
1) 安装服务
2) 装 授权 文件
3) 配 systemd + 启动自愈 hook
4) 配每日 03:00 checkpoint cron + rsync
5) 一次性全部部署 (0→1→2→3→4)

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
