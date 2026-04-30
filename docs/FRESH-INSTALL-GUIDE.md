# P4D 全新安装指南 (Fresh Install)

> 从零开始在 Ubuntu 上搭建一台全新的 Perforce P4D 服务器。
> 适用场景:第一次用 Perforce、新团队启动、独立项目专用 master。

---

## 适用场景

✅ 没有现成的 P4D,从零开始  
✅ 新团队/新项目第一台 P4D  
✅ 测试环境/沙盒  
✅ 个人/家用代码托管  

❌ **不适用**: 已有 Windows P4D 要迁移 → 看 [MIGRATION-GUIDE.md](MIGRATION-GUIDE.md)  
❌ **不适用**: 系统盘坏了要恢复 → 看 [DISK-FAILURE-RECOVERY.md](DISK-FAILURE-RECOVERY.md)

---

## 总体架构

```
学生/开发者 (P4V / p4 cli)  →  Ubuntu master:1888 (P4D)
                                     │
                                     ├─ /opt/perforce/servers/master/  (P4ROOT)
                                     ├─ /opt/perforce/backups/          (本地 14 天)
                                     └─ /mnt/nas/p4d-backups/vm1/       (NAS 90 天) [可选]
```

---

## 时间预算

| 阶段 | 时间 |
|------|------|
| Ubuntu 系统安装 | 30-60 分钟 |
| toolkit 部署 P4D | 10 分钟 |
| 初始用户/depot/protect 配置 | 15 分钟 |
| (可选) NAS 备份配置 | 30 分钟 |
| 第一个学生连接测试 | 5 分钟 |
| **合计** | **1-2 小时** |

---

## 前置准备

### 硬件

| 规模 | CPU | 内存 | 磁盘 |
|------|-----|------|------|
| 个人/小团队 (<10 人) | 2 核 | 4 GB | 100 GB SSD |
| 中等团队 (10-50 人) | 4 核 | 8 GB | 500 GB SSD |
| 大团队 (50-500 人) | 8 核 | 32 GB | 2 TB NVMe + 备份盘 |

⚠️ **数据盘空间**至少要 = 预估 depot 大小 × 3 (db + depot + checkpoint 缓冲)。

### 软件

- **Ubuntu 22.04 LTS** 或 **24.04 LTS** (其他发行版理论可行,但 toolkit 没测过)
- 装系统时建议:
  - ☑ OpenSSH Server (远程管理)
  - ☐ Docker / GUI / Snap 等其他可选组件 (生产 master 越精简越好)

### 网络

- 静态 IP 或 DHCP 绑定 (license IP-locked 时必须)
- 跟客户端在同一局域网,或者准备好路由器端口映射

### License

**两种获取方式**:

#### 选项 1: Perforce Helix Core 免费版 (5 用户)
- 直接到 https://www.perforce.com/downloads/helix-core 下载
- 永久免费,**最多 5 个用户 + 20 个 workspace**
- 适合:个人项目/小团队学习

#### 选项 2: Perforce 商业 license
- 联系 Perforce 销售: https://www.perforce.com/contact-us
- 教育版有大幅折扣,1000 user 教育 license ~$ 几千美元
- 收到 `license` 文件(没有后缀名),后面要放进 P4ROOT

⚠️ **没 license 也能装!** P4D 启动时如果没找到 license 文件,自动以 5-user 免费模式跑。后续买了 license 再放进去重启就升级了。

---

## Step 1 — 装 PVE + Ubuntu Server

### 1.1 跟视频走

直接看这两个视频,跟着做完就行,文字说明意义不大:

| 视频 | 内容 |
|------|------|
| 📺 [PVE 9.0 系统安装与初始化全攻略](https://youtu.be/hzkM0bycv4A) | PVE 虚拟化平台装好(物理机 → PVE) |
| 📺 [手把手 PVE 安装 Ubuntu Server 24,配置 SSH 登录+Docker 环境](https://youtu.be/xa5iCt0OY5w) | 在 PVE 上开 Ubuntu Server 24 + SSH |

### 1.2 装 P4D master 时的几个特殊注意点

跟视频走完之后,**装 P4D 之前**确认这几件事:

#### ⭐ 用户名
- 建议: `ubuntu` 或你个人名
- ❌ **不要用 `perforce`** (toolkit 会自动建 perforce 系统用户,会冲突)

#### ⭐ 静态 IP (重要)
P4D license 如果是 IP-locked,**新装机器必须用固定 IP**:

```bash
# 看现在 IP
ip -4 addr show
```

设静态 IP 两种方式选一种:

**方式 A: 在路由器里绑定 MAC** (推荐,最简单)
- 进路由器管理面板 → DHCP → 静态 IP 分配
- 把这台机器的 MAC 绑定到固定 IP
- Ubuntu 那边不用动配置

**方式 B: 改 Ubuntu netplan**
```bash
sudo nano /etc/netplan/00-installer-config.yaml
```
```yaml
network:
  version: 2
  ethernets:
    enp0s3:                              # 你的网卡名,可能是 ens18 / eth0
      dhcp4: false
      addresses: [192.168.1.51/24]       # 你想要的 IP
      routes:
        - to: default
          via: 192.168.1.1               # 你的网关
      nameservers:
        addresses: [192.168.1.1, 8.8.8.8]
```
```bash
sudo netplan apply
ip -4 addr show | grep inet
```

#### ⭐ 装完更新一下
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget git
```

#### ⭐ 跳过 Docker 等
视频里讲了 Docker 安装,**P4D master 不需要 Docker**,可以跳过。如果已经装了也没事,不冲突,只是多占点空间。

---

## Step 2 — 部署 P4D

### 2.1 (可选) 自定义端口/路径

默认 P4D 监听 1888,数据存 `/opt/perforce/servers/master`。要改的话:

```bash
sudo tee /etc/ssh-toolkit.conf <<'EOF'
P4PORT="1888"
P4ROOT="/opt/perforce/servers/master"
EOF
```

⚠️ **强烈建议保持 1888 默认值**(不要 1666 标准端口,容易被扫)。

### 2.2 拉 toolkit

```bash
curl -fsSL https://raw.githubusercontent.com/ziwuxin1/ssh-toolkit-linux/main/src/linux/install/ssh-toolkit.sh -o ssh-toolkit.sh
sudo bash ssh-toolkit.sh
```

### 2.3 跑菜单 0 创建工作目录

```
菜单选 0
```

会创建:
- `/root/P4_Temp/Install_Temp/` ← 放 license
- `/root/P4_Temp/Root_Temp/` ← 全新安装不用这个

会从 GitHub 自动下载 P4D 安装包 `server-2024.1.tgz` 到 `Install_Temp/`。

### 2.4 准备 license (可选)

#### 有 license 文件的:
```bash
# 把 license 上传到 Install_Temp
sudo cp /path/to/license /root/P4_Temp/Install_Temp/license
ls -la /root/P4_Temp/Install_Temp/license
```

#### 没 license 用 5-user 免费版的:
- 跳过这步
- toolkit 会让你确认"用免费版"

### 2.5 跑菜单 5 一次性部署

```
菜单选 5
```

会自动跑 0→1→2→3→4:
- ✅ 全新安装 P4D 2024.1
- ✅ 安装 license 文件 (没有的话跳过)
- ✅ 配置 systemd + 启动自愈 hook (会问你设 admin 密码)
- ✅ 配置每日 03:00 checkpoint cron 备份

⚠️ **admin 密码要求**:
- ✅ 至少 8 个字符
- ✅ 含字母 + 数字 (建议加符号)
- ❌ 不要用 `password`、`admin123` 这种弱密码
- ⭐ **记到密码管理器!** 灾难恢复时要用

例子: `P4admin@2026!Strong`

### 2.6 验证 P4D 跑起来了

```bash
sudo systemctl status p4d --no-pager | head -5
# 应该看到 active (running)

sudo /opt/perforce/bin/p4 -p localhost:1888 info
```

预期看到:
```
User name: root
Client unknown.
Server address: yourhost:1888
Server root: /opt/perforce/servers/master
Server version: P4D/LINUX26X86_64/2024.1/...
ServerID: ...
Server license: 5 users (none)        ← 免费版
   或
Server license: 你的 license 名
Case Handling: insensitive             ← Linux 上 toolkit 默认 -C0,但 -C1 兼容性最好
```

---

## Step 3 — 初始配置

P4D 跑起来了但还是空的,需要配置初始的:
- 超级用户 (admin)
- depot
- protect (权限表)
- 用户

### 3.1 登录 admin

```bash
# Toolkit 已经创建了 admin 用户(在菜单 3 时设的密码)
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin login < /opt/perforce/.p4_admin_passwd

# 验证
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin info
```

### 3.2 创建第一个 depot

P4D 默认有一个 `depot` (类型: local)。你可以直接用它,或者创建新的。

```bash
# 看现有 depot
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin depots

# 创建新 depot (例:命名为 main)
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin depot -t local main
# 这会打开编辑器,默认设置就行,保存退出

# 或者批量自动创建
echo "Depot: main
Owner: admin
Date: $(date '+%Y/%m/%d %H:%M:%S')
Description: Main project depot
Type: local
Map: main/..." | sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin depot -i
```

⚠️ depot 命名规范:
- 全小写或全大写,内部用 `_` 分隔
- 不要用空格、中文、特殊字符
- 例: `main`, `2026_gamedesign`, `MAXS_Internal`

### 3.3 配置 protect (权限表)

⚠️ **新装的 P4D protect 表是空的,任何人都是 super!** 必须立刻配置。

```bash
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin protect
```

会打开编辑器,默认内容大概是:
```
Protections:
    write user * * //...
    super user admin * //...
```

第一行 `write user * *` 意思是任何 IP 任何用户都能写所有 depot 路径。**生产环境必须改**。

### 3.4 推荐的 protect 配置

```
Protections:
    # 默认拒绝所有(白名单原则)
    list user *      *  -//...
    
    # admin 是 super,可以做一切
    super user admin *  //...
    
    # 局域网内的所有人能读所有 depot
    read user *      192.168.1.0/24  //...
    
    # 学生组可以读写自己的项目
    write group students 192.168.1.0/24  //main/...
    write group students *               //2026_gamedesign/...
    
    # admin 组可以从任何 IP 读写所有
    write group admins  *               //...
```

### 3.5 创建用户组

```bash
# 创建 students 组
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin group students
# 编辑器里 Users: 那段加学生用户名,一行一个
```

```bash
# 创建 admins 组
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin group admins
# Users: 加 admin 和其他超级管理员
```

### 3.6 创建第一个学生用户

#### 方式 1: 学生自己注册 (推荐)

让学生在自己电脑上跑:
```cmd
p4 -p MASTER_IP:1888 user
# 编辑器里填邮箱/姓名,保存退出
```

P4D 会自动创建用户。然后他们设密码:
```cmd
p4 -p MASTER_IP:1888 -u 学生用户名 passwd
```

#### 方式 2: admin 批量创建

```bash
# 创建用户 zhang.san
echo "User: zhang.san
Email: zhang.san@example.com
FullName: Zhang San
Type: standard" | sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin user -i -f

# 给他设初始密码
echo -e "InitialPasswd123!\nInitialPasswd123!" | sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin passwd zhang.san

# 加入 students 组
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin group students
# 在 Users: 那段加上 zhang.san
```

### 3.7 (可选) 设置安全级别

```bash
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin configure set security=2
```

| level | 要求 |
|-------|------|
| 0 | 默认,密码可选 |
| 1 | 强制密码 + 必须 8 字符 |
| 2 | 强密码(加上要包含字母数字符号) + ticket 强制 |
| 3 | level 2 + 不允许保存密码 |
| 4 | level 3 + 强制 SSL |

教学环境推荐 level 1,公网暴露推荐 level 3+SSL。

---

## Step 4 — (可选) 配置 NAS 双副本备份

如果你有 NAS,建议配置一下,详细见 [MIGRATION-GUIDE.md](MIGRATION-GUIDE.md#phase-4--nas-双副本备份)。

简版:

```bash
sudo apt install -y nfs-common
sudo mkdir -p /mnt/nas/p4d-backups/vm1
sudo mount -t nfs4 NAS_IP:/volume1/P4D /mnt/nas/p4d-backups/vm1

# 测能写
sudo -u perforce touch /mnt/nas/p4d-backups/vm1/_writetest && \
  sudo rm /mnt/nas/p4d-backups/vm1/_writetest

# fstab
echo "NAS_IP:/volume1/P4D /mnt/nas/p4d-backups/vm1 nfs4 rw,async,_netdev,noatime,nofail 0 0" | sudo tee -a /etc/fstab

# 重跑菜单 4 让 cron 用上 NAS
sudo bash ssh-toolkit.sh   # 选 4
```

⚠️ 没 NAS 也行,本地 14 天 checkpoint 也是基本备份(只是失去"异地"那一层保护)。

---

## Step 5 — 客户端连接测试

### 5.1 在你自己电脑上 (Mac/Windows/Linux 都行)

#### 命令行 p4

下载: https://www.perforce.com/downloads/helix-command-line-client-p4

```bash
# Linux/Mac
export P4PORT=192.168.1.51:1888
export P4USER=admin

# Windows PowerShell
$env:P4PORT = "192.168.1.51:1888"
$env:P4USER = "admin"

# 连
p4 info
p4 login   # 输入 admin 密码
```

#### 图形客户端 P4V

下载: https://www.perforce.com/downloads/helix-visual-client-p4v

第一次启动:
- Server: `192.168.1.51:1888`
- User: `admin`
- 点 OK,输入密码

### 5.2 创建第一个 workspace + sync

#### 命令行
```bash
# 看现有 workspace
p4 clients

# 创建新 workspace
p4 client my_first_workspace
# 编辑器里:
# Root: /home/你/perforce/my_first_workspace  ← 本地工作目录
# View: 
#   //main/... //my_first_workspace/main/...
# 保存

# 现在 cd 到工作目录
mkdir -p /home/你/perforce/my_first_workspace
cd /home/你/perforce/my_first_workspace
export P4CLIENT=my_first_workspace

# sync (空的 depot 没东西可拉,这步会跳过)
p4 sync
```

### 5.3 第一次 submit 测试

```bash
# 创建一个测试文件
echo "Hello P4D" > test.txt

# add → submit
p4 add test.txt
p4 submit -d "First commit ever"

# 看 changelist
p4 changes
# 应该看到 Change 1 by admin@... 'First commit ever'
```

如果这步成功,**P4D 全部配置完成,可以投入使用**。

---

## Step 6 — 公网暴露 (可选)

如果学生在外网,需要让公网访问 P4D。详细见 [MIGRATION-GUIDE.md](MIGRATION-GUIDE.md#phase-5--公网暴露)。

简版:

### 路由器端口映射
| 字段 | 值 |
|------|------|
| 协议 | TCP |
| 内部 IP | 你 master 的局域网 IP |
| 内部端口 | 1888 |
| **外部端口** | **28888** (高位端口防扫描) |

### 强烈建议: 启用 SSL

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

学生连接:
```
P4PORT=ssl:你家公网IP:28888
```

---

## 常见问题

### Q1: P4D 启动后 license 显示 "5 users (none)"

正常 — 没放 license 文件 P4D 自动用 5-user 免费版。够 5 个学生用。

要升级到正式 license:
```bash
sudo cp 你的license /opt/perforce/servers/master/license
sudo chown perforce:perforce /opt/perforce/servers/master/license
sudo systemctl restart p4d
```

### Q2: admin 密码忘了怎么办?

```bash
# 停服务
sudo systemctl stop p4d

# 用维护模式启动 P4D
sudo -u perforce /opt/perforce/sbin/p4d -r /opt/perforce/servers/master -p 1888 &
sleep 3

# 直接修改 admin 密码(不需要旧密码)
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin passwd

# 更新 toolkit 的 admin 密码文件
echo -n "新密码" | sudo tee /opt/perforce/.p4_admin_passwd
sudo chown perforce:perforce /opt/perforce/.p4_admin_passwd
sudo chmod 600 /opt/perforce/.p4_admin_passwd

# 关掉手动启动,用 systemd 接管
sudo pkill -f "p4d -r"
sleep 1
sudo systemctl start p4d
```

### Q3: 学生连不上,报 "Connect to server failed"

检查清单:
```bash
# 1. P4D 在跑吗
sudo systemctl is-active p4d

# 2. 监听端口
sudo ss -tlnp | grep 1888

# 3. 防火墙
sudo ufw status

# 4. 学生那边能 ping 通吗
# 在学生电脑上: ping 你的IP

# 5. 端口开放(学生电脑跑)
# Windows: Test-NetConnection -ComputerName 你IP -Port 1888
# Mac/Linux: nc -zv 你IP 1888
```

### Q4: case-handling 是 sensitive 还是 insensitive?

**新装 P4D 在 Linux 上默认是 sensitive (-C0)**:
- `Foo.txt` ≠ `foo.txt` (两个不同文件)
- 跨平台协作可能踩坑(Windows 学生上传 `Foo.txt`,Mac 学生 sync 后看到 `Foo.txt`,但他们建文件命名 `foo.txt` 会被当成新文件)

**推荐: 装的时候改成 insensitive (-C1)**:
- `Foo.txt` = `foo.txt` (视为同一文件)
- 跟 Windows P4D 行为一致
- ⚠️ db 创建时锁定,**装好后不能改!**

如果你**还没跑过菜单 1**,可以这样让 toolkit 用 -C1 装:

修改 `/etc/ssh-toolkit.conf` 加(目前 toolkit 还没暴露这个选项,得手动跑 -jr):
```bash
# 不要用 toolkit 菜单 1,改用手动:
sudo systemctl stop p4d
sudo find /opt/perforce/servers/master -maxdepth 1 -name "db.*" -delete

# 用 -C1 初始化 db
sudo -u perforce /opt/perforce/sbin/p4d -r /opt/perforce/servers/master -C1 -xi

# 然后跑菜单 2/3/4
```

或者更简单 — **混合学生用了 Windows + Mac 时,推荐 -C1**;**纯 Linux 团队,推荐默认 -C0 (sensitive)**。

### Q5: 如何添加大量用户?

写个简单脚本:
```bash
#!/bin/bash
# add_users.sh
USERS=(
    "zhang.san:zhang.san@example.com:Zhang San"
    "li.si:li.si@example.com:Li Si"
    "wang.wu:wang.wu@example.com:Wang Wu"
)

for u in "${USERS[@]}"; do
    IFS=':' read -r username email fullname <<< "$u"
    
    echo "User: $username
Email: $email
FullName: $fullname
Type: standard" | sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin user -i -f
    
    # 设初始密码
    echo -e "TempPass123!\nTempPass123!" | sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin passwd $username
    
    echo "✓ 创建用户 $username"
done

echo "全部完成。学生第一次登录后让他们改密码:"
echo "  p4 passwd"
```

### Q6: 我应该多久备份?

| 数据重要程度 | 推荐备份频率 |
|------------|-----------|
| 教学/沙盒 | 默认每天 03:00 cron 就够 |
| 学生作业 (RPO 24h 可接受) | 默认每天 03:00 |
| 商业项目 (RPO 1h) | 加每小时 live journal rsync |
| 关键业务 (RPO≈0) | standby replica 实时复制 |

详见 [DISK-FAILURE-RECOVERY.md](DISK-FAILURE-RECOVERY.md#加固方案)。

---

## 第一周必做事项

### Day 1 (今天)
- [x] 装 Ubuntu + 静态 IP
- [x] 跑 toolkit 菜单 5
- [x] 创建第一个 depot + protect 配置
- [x] 第一次 submit 测试

### Day 2
- [ ] 加学生用户 + 分组
- [ ] 让一个学生连上来 sync/submit
- [ ] 配置 NAS 备份(如果有)

### Day 3-7
- [ ] 全部学生都上线
- [ ] 第一次自动 cron 备份成功(看健康体检)
- [ ] 路由器映射 + SSL(如果对外)
- [ ] 文档化你的 admin 密码 + license 位置

### 第一个月
- [ ] 跑一次灾难恢复演练 (用虚拟机)
- [ ] 监控磁盘使用增长趋势
- [ ] 学生培训(P4V 基本操作)

---

## 推荐学生培训资料

**Perforce 官方**:
- P4V 入门: https://www.perforce.com/manuals/p4v/
- p4 cli 入门: https://www.perforce.com/manuals/p4guide/
- 视频教程: https://www.perforce.com/video-tutorials

**实用工作流**:
```bash
# 学生每天的标准操作
p4 sync                  # 拉最新
p4 edit some_file.txt    # 锁定准备改
# ...编辑文件...
p4 diff                  # 看自己改了啥
p4 submit -d "fix bug"   # 提交
```

**冲突处理**:
```bash
p4 sync                  # 拉最新
# 发现冲突时:
p4 resolve               # 进入 resolve 模式
# 或:
p4 resolve -am           # 自动合并所有
```

---

## 检查清单 - 全新部署完成度

```
□ Ubuntu 系统装好 + 静态 IP
□ toolkit 菜单 5 全跑完
□ P4D 服务 active running
□ License 状态正常 (商业版或 5-user 免费)
□ admin 用户能登录
□ admin 密码记到密码管理器了
□ 至少创建 1 个 depot
□ protect 表配置好(不是默认的全员 super)
□ 至少 1 个学生用户能 sync/submit
□ Cron 03:00 自动备份配置好
□ (可选) NAS NFS 挂载 + 测试 rsync
□ (可选) 路由器映射 + 公网测试
□ (可选) SSL 启用
□ 灾难恢复指南打印贴在机房 [DISK-FAILURE-RECOVERY.md]
```

全部打钩 = **生产可用**。

---

## 命令速查

```bash
# 服务管理
sudo systemctl status p4d
sudo systemctl restart p4d
sudo bash ssh-toolkit.sh              # 进 toolkit 菜单

# 用户/depot/protect
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin login < /opt/perforce/.p4_admin_passwd
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin users
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin depots
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin protect
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin groups

# 实时看 P4D 日志
sudo journalctl -u p4d -f

# 看健康状态
sudo bash ssh-toolkit.sh status        # 非交互模式
```

---

## 下一步学习

| 文档 | 用途 |
|------|------|
| [迁移指南](MIGRATION-GUIDE.md) | 以后从别的 master 迁移过来 |
| [灾难恢复](DISK-FAILURE-RECOVERY.md) | 系统盘坏了怎么办 |
| Perforce 官方文档 | https://www.perforce.com/manuals/ |

---

*最后更新: 2026-04-30*
