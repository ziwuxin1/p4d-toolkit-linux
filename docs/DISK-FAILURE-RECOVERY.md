# Ubuntu 系统硬盘损坏 - P4D 完整恢复指南

> 当 Ubuntu master 主机硬盘完全损坏(SSD 死了、整机被偷、机房着火),
> 用 NAS 上的备份在新机器上重建 P4D,**学生数据零丢失**。

---

## 适用场景

✅ Ubuntu 系统盘 SSD 完全损坏  
✅ 整台 master 主机被偷/被损坏  
✅ 机房着火/水淹  
✅ 系统盘 RAID 整体失效  
✅ 误操作 `rm -rf /` 之类的人为灾难  

**前提**: NAS 还活着,`/mnt/nas/p4d-backups/vm1/` 里有最近的备份。

---

## 恢复时间线 (RTO/RPO)

| 指标 | 值 | 备注 |
|------|-----|------|
| **RPO** (能丢多少数据) | **最多 24 小时** | 上次 cron 备份到事故之间的变更 |
| **RTO** (多久能恢复) | **3-5 小时** | 装系统 + 拉数据 + 启动 P4D |

如果 RPO 24 小时不够,看文末的"加固方案"。

---

## 总览 - 灾难恢复 6 步

```
1. 准备新机器 (1 小时)
   └─ 装 Ubuntu 22.04/24.04 + 静态 IP + SSH

2. 跑 toolkit 部署 P4D (15 分钟)
   └─ 菜单 1-4 装 P4D + license + systemd + cron

3. 挂 NAS (10 分钟)
   └─ 装 nfs-common + mount + 验证能读

4. 从 NAS 拉数据 (1-2 小时)
   ├─ checkpoint + journal → /opt/perforce/backups
   └─ depot 物理文件 → /opt/perforce/servers/master/

5. 跑 toolkit 菜单 7 一键恢复 (5-15 分钟)
   └─ 自动 replay checkpoint + journal + 启动

6. 验证 + 通知学生 (30 分钟)
   └─ depot 列表/用户/changelist + 学生连测试
```

---

## Step 1 — 准备新机器

### 1.1 硬件要求

新机器至少要:
- **磁盘空间**: depot 总大小 × 1.5 (恢复期间临时空间)
- **网卡**: 跟 NAS 在同一局域网 (千兆以上)
- **架构**: x86_64 (P4D 二进制版本要对得上)

⚠️ **磁盘空间必须够**。如果原 master 是 1TB,新机器至少要 1.5TB。

### 1.2 装 Ubuntu

跟原来一样的版本:Ubuntu 22.04 LTS 或 24.04 LTS。

装的时候注意:
- 选 OpenSSH Server
- 时区跟 NAS 一致
- 用户名建议跟原来一样(后面 chown 会方便些)

### 1.3 设静态 IP

⚠️ **关键**: 如果你的 license 是 IP-locked,**新机器必须用同一个 IP**!

```bash
# 看现在的 IP
ip -4 addr show

# 如果不对,改 netplan
sudo nano /etc/netplan/00-installer-config.yaml
```

例子:
```yaml
network:
  version: 2
  ethernets:
    ens18:
      dhcp4: false
      addresses: [192.168.1.51/24]
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses: [192.168.1.1, 8.8.8.8]
```

```bash
sudo netplan apply
ip -4 addr show | grep inet
```

### 1.4 验证基础网络

```bash
# 能访问 NAS
ping -c 3 192.168.1.230

# 能访问外网(下载 toolkit + tgz)
curl -fsSL https://raw.githubusercontent.com/ziwuxin1/ssh-toolkit-linux/main/README.md | head -3
```

---

## Step 2 — 部署 P4D

### 2.1 拉 toolkit

```bash
curl -fsSL https://raw.githubusercontent.com/ziwuxin1/ssh-toolkit-linux/main/src/linux/install/ssh-toolkit.sh -o ssh-toolkit.sh
```

### 2.2 (可选) 写配置文件

如果原来用的不是默认端口/路径,先写:

```bash
sudo tee /etc/ssh-toolkit.conf <<'EOF'
P4PORT="1888"
P4ROOT="/opt/perforce/servers/master"
EOF
```

### 2.3 跑菜单 0/1/2/3/4

⚠️ **不要按菜单 5 一次性部署**! 5 会跑 0→1→2→3→4 但中间需要你放 license 文件。

```bash
sudo bash ssh-toolkit.sh
# 选 0 → 创建工作目录 + 下载 P4D tgz
```

### 2.4 准备 license

⚠️ **license 文件你需要保留备份**。从你的密码管理器/U 盘/邮箱拿出来。

```bash
# 把 license 文件放到 Install_Temp
sudo cp /path/to/license /root/P4_Temp/Install_Temp/license
ls -la /root/P4_Temp/Install_Temp/license
```

> 💡 **后续保险措施**: license 文件也可以放进 NAS 备份。建议加一条 cron 把 license 同步到 NAS:
> ```bash
> 0 2 * * * root cp /opt/perforce/servers/master/license /mnt/nas/p4d-backups/vm1/
> ```

### 2.5 跑菜单 1/2/3/4

```bash
sudo bash ssh-toolkit.sh

# 选 1 → 全新安装 P4D 2024.1
# 选 2 → 安装 license
# 选 3 → 配置 systemd + 自愈 hook (会让你输入 admin 密码,用原来的)
# 选 4 → 配置每日 03:00 cron 备份
```

⚠️ **admin 密码必须跟原来一致**! 新装的 P4D 此时数据库是空的,密码无所谓;但跑菜单 7 恢复后,db 里的 admin 用户会回来,届时要用**原密码**才能 ExecStartPost 自动登录。

如果忘了原密码:

```bash
# 等 menu 7 恢复完之后再改:
sudo systemctl stop p4d
sudo -u perforce /opt/perforce/sbin/p4d -r /opt/perforce/servers/master -p localhost:1888 &
sleep 2
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin passwd  # 设新密码
echo -n "新密码" | sudo tee /opt/perforce/.p4_admin_passwd
sudo chown perforce:perforce /opt/perforce/.p4_admin_passwd
sudo chmod 600 /opt/perforce/.p4_admin_passwd
sudo pkill -f "p4d -r"
sudo systemctl start p4d
```

### 2.6 验证 P4D 跑起来了

```bash
sudo systemctl status p4d --no-pager | head -5
# Active: active (running)
```

⚠️ 此时 P4D 是个**空数据库**,只是壳子。下面去拉数据。

---

## Step 3 — 挂 NAS

### 3.1 装 NFS 客户端

```bash
sudo apt update && sudo apt install -y nfs-common
```

### 3.2 挂载

⚠️ **群晖那边的 NFS 权限规则**通常**绑定客户端 IP**。如果新机器 IP 跟原来不一样,要先去群晖加规则:

```
控制面板 → 共享文件夹 → P4D-MAXs → 编辑 → NFS 权限 → 新增
服务器 IP: 新机器 IP
权限: 读写
Squash: 将所有用户映射到 admin
```

然后 Linux 端:

```bash
NAS_IP="192.168.1.230"
NAS_PATH="/volume1/P4D-MAXs"
sudo mkdir -p /mnt/nas/p4d-backups/vm1
sudo mount -t nfs4 ${NAS_IP}:${NAS_PATH} /mnt/nas/p4d-backups/vm1

# 验证
df -h /mnt/nas/p4d-backups/vm1
ls /mnt/nas/p4d-backups/vm1/
# 应该看到 checkpoints/  depots/
```

### 3.3 fstab 持久化

```bash
echo "${NAS_IP}:${NAS_PATH} /mnt/nas/p4d-backups/vm1 nfs4 rw,async,_netdev,noatime,nofail 0 0" | sudo tee -a /etc/fstab
sudo mount -a
```

---

## Step 4 — 从 NAS 拉数据

### 4.1 看 NAS 上有什么

```bash
ls -la /mnt/nas/p4d-backups/vm1/checkpoints/
ls -la /mnt/nas/p4d-backups/vm1/depots/

du -sh /mnt/nas/p4d-backups/vm1/depots/
```

预期看到:
```
checkpoints/
├── checkpoint.NNN
├── checkpoint.NNN.md5
└── journal.NNN-1   (历史 journal,已轮转)

depots/
├── depot1/
├── depot2/
└── ...
```

⚠️ **NAS 上没有 live journal**! 因为 cron 推送时排除了。这意味着:
- 上次 03:30 cron 之后到事故之间的变更**会丢失**(就是 RPO 24 小时的来源)
- 如果你能从损坏的系统盘上**抢救出 live journal**,可以减少损失(见文末"加固方案")

### 4.2 拉 checkpoint + journal 到本地

```bash
# 先停 P4D (新装的空数据库,关掉以便恢复)
sudo systemctl stop p4d

# 拉到 backups 目录(toolkit 会自动用)
sudo cp /mnt/nas/p4d-backups/vm1/checkpoints/checkpoint.NNN /opt/perforce/backups/
sudo cp /mnt/nas/p4d-backups/vm1/checkpoints/checkpoint.NNN.md5 /opt/perforce/backups/

# 看看有没有历史 journal 也拉过来
sudo cp /mnt/nas/p4d-backups/vm1/checkpoints/journal.* /opt/perforce/backups/ 2>/dev/null || true

sudo chown -R perforce:perforce /opt/perforce/backups/
ls -la /opt/perforce/backups/
```

⚠️ 注意 NNN 是最新的数字,例如 checkpoint.152。

### 4.3 拉 depot 物理文件

这一步**最耗时**(几百 GB - 几 TB)。

```bash
# 先确保 P4ROOT 里没有冲突的 db.*
sudo systemctl is-active p4d   # 应该 inactive
sudo find /opt/perforce/servers/master -maxdepth 1 -name "db.*" -delete

# rsync 拉回来(注意方向: NAS → 本地)
sudo rsync -av --no-owner --no-group --no-perms --human-readable \
    /mnt/nas/p4d-backups/vm1/depots/ \
    /opt/perforce/servers/master/

# 改所有者
sudo chown -R perforce:perforce /opt/perforce/servers/master/
sudo chmod -R u+rwX,go+rX /opt/perforce/servers/master/

# 验证大小
du -sh /opt/perforce/servers/master/
du -sh /opt/perforce/servers/master/*/ | head
```

⚠️ **rsync 速度参考**:
- 千兆 LAN: 80-110 MB/s → 1TB ≈ 3 小时
- 2.5G LAN: 200-300 MB/s → 1TB ≈ 1 小时
- 10G LAN: 500-1000 MB/s → 1TB ≈ 30 分钟

进度可以新开 SSH 窗口看:
```bash
watch -n 30 'du -sh /opt/perforce/servers/master/'
```

---

## Step 5 — 跑 toolkit 菜单 7 一键恢复

### 5.1 把 checkpoint 也放到 Root_Temp(toolkit 默认从这找)

```bash
# 其实 toolkit 现在会自动从 BACKUP_DIR 找,但放到 Root_Temp 也行
ls /opt/perforce/backups/checkpoint.* /opt/perforce/backups/journal.* 2>/dev/null
# 看到 checkpoint.NNN + checkpoint.NNN.md5 就够了
```

### 5.2 跑菜单 7

```bash
sudo bash ~/ssh-toolkit.sh
# 选 7
# 输入 CONFIRM
```

预期输出:
```
🚀 一键恢复
ℹ 来源目录: /opt/perforce/backups
ℹ 最新 checkpoint: /opt/perforce/backups/checkpoint.152 (#152)
ℹ 需要 replay 的 journal 数: 0
ℹ 检测 checkpoint case 模式...
ℹ Checkpoint 声明 case 模式: -C1 (Windows hybrid)
ℹ Replay /opt/perforce/backups/checkpoint.152 -C1
ℹ 注入 counter=0 jnl
ℹ 启动服务
ℹ Counter 校准: ...
```

⚠️ 如果脚本报错"checkpoint replay failed at line N",看具体错误信息。常见的:
- **Permission denied**: 脚本会自动 stage 到 perforce 可读位置
- **Case-handling mismatch**: 脚本会自动用 -C1 重试
- **磁盘空间不够**: `df -h` 看 P4ROOT 所在分区

### 5.3 (高级) 恢复抢救出的 live journal

如果你**从损坏的系统盘上抢救出了 live journal**(比如硬盘只是控制器挂了,数据还在):

```bash
# 在跑菜单 7 之前,把 live journal 也放进 backups
sudo cp /path/to/rescued/journal /opt/perforce/backups/journal
sudo chown perforce:perforce /opt/perforce/backups/journal

# 然后跑菜单 7,它会:
# 1. Replay checkpoint
# 2. Replay journal (live, 包含最后的变更)
# 3. 数据丢失从 24 小时缩到 0
```

---

## Step 6 — 验证 + 通知

### 6.1 全面验证

```bash
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin login < /opt/perforce/.p4_admin_passwd

# 1. License 还活着吗?
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin info | grep -i license
# Server license: admin 1000 users (...)   ← 不应该是 none 或 5-user

# 2. Case 模式对吗?
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin info | grep -i case
# Case Handling: insensitive

# 3. depot 列表
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin depots
# 跟原来一样

# 4. 用户数
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin users | wc -l

# 5. 最新 changelist
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin changes -m 5

# 6. 关键: counter 校准了
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin counter change
# 应该 ≈ MAX changelist + 1
```

### 6.2 跑 verify 确认 archive 完整性

```bash
# 后台跑(30-60 分钟)
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin verify -q //... 2>&1 | tee /tmp/verify-recovery.log &

# 完事看
grep -c 'MISSING!' /tmp/verify-recovery.log
grep -c 'BAD!' /tmp/verify-recovery.log
```

⚠️ MISSING/BAD > 0 时:
- 看哪些文件丢/坏,通知对应学生重传
- 检查 NAS 上是不是真的有那些文件

### 6.3 客户端测试

让你自己或一个学生试试:

```bash
# 学生那边
export P4PORT=新master_IP:1888
export P4USER=他们的用户名
p4 login   # 用原密码
p4 sync //somedepot/...@latest  # 测试 sync
```

能拉文件下来 → **恢复成功** ✅

### 6.4 通知所有学生

如果新 master 的 IP 跟原来不一样,所有学生都要改 P4PORT。发个简短通知:

```
P4D master 已迁移到新主机,从 [新日期] 起请改连接:

旧: P4PORT=192.168.1.51:1888
新: P4PORT=新IP:1888

改完正常 sync/submit 即可,workspace/changelist 历史/密码全部不变。
如果 sync 报 "file(s) not in client view" 或类似,
试试: p4 client (重新提交 client spec)
```

---

## ⚠️ 加固方案 (减少 RPO)

默认 RPO 是 24 小时(上次 cron 03:30 之后的变更全丢)。要降低,有几种方案:

### 方案 A: 提高 cron 频率

```bash
# /etc/cron.d/p4d-backup 加一行:
# 每小时增量推 live journal
0 * * * * root rsync -a --no-owner --no-group --no-perms \
    /opt/perforce/servers/master/journal \
    /mnt/nas/p4d-backups/vm1/checkpoints/journal.live 2>&1 \
    >> /var/log/p4d-journal-rsync.log
```

RPO 缩到 1 小时。

### 方案 B: 实时 journal 复制 (Perforce standby replica)

部署第二台机器作为 standby,实时同步 journal。

```
master (写) → journal stream → standby (读,实时跟随)
```

灾难时切换到 standby:RPO ≈ 0,RTO 几分钟。复杂度高,适合关键业务。

### 方案 C: 快照备份系统盘

用 LVM/ZFS/Btrfs 快照,或者整盘 dd 到外置硬盘:

```bash
# 每天凌晨快照 P4ROOT (LVM)
0 2 * * * root lvcreate --size 100G --snapshot --name p4d_snap_$(date +\%Y\%m\%d) /dev/vg0/p4root
```

灾难时 mount 快照,数据是事故那一刻的状态。RPO 0,RTO 分钟级。

### 方案 D: 异地 NAS 备份

主 NAS 再 rsync 到异地 NAS(比如 Backblaze B2 / 阿里云 OSS):
```bash
# 群晖 → 云对象存储,Synology Cloud Sync 自带
```

主 NAS 也挂了的话还有云端兜底。

---

## 常见问题

### Q1: License 报 "Server license: none" 怎么办?

可能原因:
1. License 文件没拷过来 → 重新放到 P4ROOT/license
2. License IP-locked,新机器 IP 不对 → 改回原 IP 或联系 Perforce 改 license
3. License 过期了

```bash
# 看 license 内容
sudo cat /opt/perforce/servers/master/license

# 重启让 P4D 重新读
sudo systemctl restart p4d
```

### Q2: 学生 client spec 还在吗?

**在**。Client spec 存在 db.have / db.client 表里,跟着 checkpoint 一起恢复了。学生不用重新建 workspace。

### Q3: 学生本地工作目录怎么办?

不影响。学生本地的文件还在,他们只需:
```bash
p4 sync           # 重新同步状态(P4D 会比对 client spec 和实际文件)
p4 reconcile      # 万一有差异,重新对账
```

### Q4: counter 漂移怎么办?

```bash
sudo bash ~/ssh-toolkit.sh
# 选 6: Counter 救援
```

或者重启 P4D,自愈 hook 会自动修。

### Q5: NAS 上数据也丢了?

那就只能靠:
- 学生本地工作目录(他们的最新提交)
- 如果有云端备份(方案 D),从云端拉

如果什么都没了,**只能损失全部数据**。所以 NAS 别只放一份,做异地备份很重要。

### Q6: 我没保留 license 文件?

紧急联系 Perforce support: support@perforce.com 或 https://www.perforce.com/support

通常凭购买合同 + admin 邮箱能补发。**这就是为什么要把 license 也加进 NAS 备份**。

---

## 演练建议

⚠️ 不要等真灾难发生才第一次跑这流程。建议:

### 每季度做一次"灾难演练"

1. 找一台空闲机器(虚拟机也行)
2. 装 Ubuntu + 跑这份指南
3. 从 NAS 恢复成功 = 验证备份系统真的能用
4. 演练完销毁这台测试机

### 每年做一次完整切换演练

1. 准备好新机器
2. 通知所有学生暂停半小时
3. 真的从 NAS 恢复到新机器
4. 切换 IP / DNS,让学生连新机器
5. 验证一切正常 → 保留新机器,旧机器拆掉
6. 没验证通过 → 切回旧机器,事后查问题

这样真灾难来时,你已经做过 N 次,流程肌肉记忆了。

---

## 检查清单

打印或抄到笔记本上,真出事时按这个走:

```
□ 0. 冷静!深呼吸,数据在 NAS 上,不会丢
□ 1. 确认 NAS 还活着 (ping NAS_IP)
□ 2. 准备新机器,装 Ubuntu + SSH + 静态 IP
□ 3. 拉 toolkit: curl ... | sudo bash
□ 4. 跑菜单 1/2/3/4 (准备 license)
□ 5. 装 nfs-common + 挂 NAS
□ 6. cp checkpoint+journal 到 /opt/perforce/backups/
□ 7. rsync depot 从 NAS 到 P4ROOT (chown perforce)
□ 8. 跑菜单 7 一键恢复
□ 9. p4 info 看 license / case / depots
□ 10. p4 verify -q //... 检查完整性
□ 11. 通知学生新连接信息
□ 12. 庆祝 🎉
```

---

## 附录: 关键命令速查

```bash
# 看 NAS 备份多大
du -sh /mnt/nas/p4d-backups/vm1/

# 拉 checkpoint 到本地
sudo cp /mnt/nas/p4d-backups/vm1/checkpoints/checkpoint.* /opt/perforce/backups/

# rsync depot 从 NAS 到 P4ROOT
sudo rsync -av --no-owner --no-group --no-perms \
    /mnt/nas/p4d-backups/vm1/depots/ \
    /opt/perforce/servers/master/

# 改所有者
sudo chown -R perforce:perforce /opt/perforce/servers/master/

# 一键恢复
sudo bash ~/ssh-toolkit.sh   # 选 7

# 验证完整性
sudo /opt/perforce/bin/p4 -p localhost:1888 -u admin verify -q //...
```

---

*最后更新: 2026-04-30 — 基于 1.13TB 双 master 实战 + 灾难恢复演练*
