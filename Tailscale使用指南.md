# Tailscale 直连 + 挂载工作盘 —— 零基础指南

目标:不再经过跳板机,你的 Windows 11 与云主机之间建立加密直连;并把服务器上的 `workspace/` 挂成 Windows 的一个盘符,拖拽文件如同本地操作。

提醒:如果跳板机是公司合规要求,启用前先与运维确认。

## 目录

1. [Tailscale 是什么](#一tailscale-是什么)
2. [注册账号](#二注册账号)
3. [服务器端安装](#三服务器端安装)
4. [Windows 端安装与直连验证](#四windows-端安装与直连验证)
5. [必做的一项设置:关闭服务器的密钥过期](#五必做关闭服务器的密钥过期)
6. [Samba:把 workspace 挂成 Windows 盘符](#六samba把-workspace-挂成-windows-盘符)
7. [接入后日常方式的变化](#七接入后日常方式的变化)
8. [安全加固](#八安全加固)
9. [故障排查](#九故障排查)

## 一、Tailscale 是什么

- 基于 WireGuard 的**点对点加密组网**工具:装了客户端并登录同一账号的设备,自动组成一张虚拟内网(叫 **tailnet**),彼此用 `100.x.y.z` 的内网 IP 互访。
- **两端都能出公网即可直连**,不需要公网 IP、不需要开防火墙端口、不需要跳板中转——它会自动做 NAT 穿透;穿不透时走官方中继(流量仍是端到端加密,中继看不到内容)。
- 你的账号就是网络边界:设备凭账号授权加入,不在 tailnet 里的设备根本"看不见"这些 100.x 地址。
- 免费个人版(3 用户 100 台设备)对本场景绰绰有余。

## 二、注册账号

1. 浏览器打开 https://login.tailscale.com/start
2. 选择用 Google / Microsoft / GitHub 账号登录(Tailscale 自己不设密码,复用这些账号的登录体系)
3. **立即给你选的这个账号开启两步验证(MFA)**——这个账号被盗 = 陌生设备可以加入你的内网,这是整个方案最重要的一根锁

## 三、服务器端安装

以 `davis` 登录服务器执行:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
                              # 官方安装脚本:自动识别发行版、添加官方 apt 源并安装
sudo tailscale up             # 启动并加入你的 tailnet
                              # 终端会打印一个 https://login.tailscale.com/a/xxxx 的链接
```

把打印出的链接复制到**本地电脑浏览器**打开 → 用第二步的账号登录 → 点 Connect 授权。回到终端会显示 Success。

```bash
tailscale ip -4               # 查看本机分到的 tailnet IP,形如 100.x.y.z —— 记下来,后文都用它
tailscale status              # 查看 tailnet 里的设备列表与连接状态
```

安装脚本会注册 systemd 服务(tailscaled),服务器重启后自动上线,无需再管。

## 四、Windows 端安装与直连验证

1. 打开 https://tailscale.com/download/windows 下载安装包并安装(或 Microsoft Store 搜 Tailscale)
2. 安装后系统托盘出现 Tailscale 图标 → 点击 → Log in → 用**同一账号**登录授权
3. 托盘图标菜单里能看到你的服务器名字,说明两台设备已在同一张网里

验证直连(本地 PowerShell):

```powershell
ping 100.x.y.z                # 应有响应(把 100.x.y.z 换成第三步记下的服务器 IP)
ssh davis@100.x.y.z           # 直接 SSH,不再经过跳板机;密钥认证照常生效
```

Tabby 里新建一个直连 profile:主机填 `100.x.y.z`,认证选你现有的私钥文件,**不需要再配 jump host**。原有的跳板 profile 保留作备用通道即可。

```powershell
tailscale ping 100.x.y.z      # 进阶:显示连接是 direct(点对点)还是 DERP(中继)
                              # direct 延迟低;显示 relay 也能用,只是绕了中继
```

## 五、必做:关闭服务器的密钥过期

Tailscale 默认每台设备的节点密钥 **180 天过期**,过期后需要重新 `tailscale up` 认证——对服务器来说等于半年后突然失联。

1. 打开管理台 https://login.tailscale.com/admin/machines
2. 找到服务器那一行 → 右侧 `...` 菜单 → **Disable key expiry**

你自己的 Windows 设备可以不关(到期重新登录一下就行),服务器必须关。

## 六、Samba:把 workspace 挂成 Windows 盘符

### 6.1 服务器端配置

```bash
sudo apt install -y samba     # 安装 SMB 文件共享服务(Windows 网络驱动器用的就是 SMB 协议)

sudo tee -a /etc/samba/smb.conf <<'EOF'
                              # 向 samba 主配置追加以下内容(EOF 之间原样写入文件)

[global]
   interfaces = lo 100.x.y.z
   bind interfaces only = yes

[workspace]
   path = /home/davis/ai-agents/workspace
   read only = no
   valid users = davis
EOF
```

逐行说明:

- `interfaces = lo 100.x.y.z`:SMB 只监听回环和你的 tailnet IP(**写第三节记下的具体 IP,不要写网卡名 tailscale0**——它是点对点 /32 接口,Samba 按名字经常识别不到,写 IP 最稳)
- `bind interfaces only = yes`:严格只绑上面两个接口——**公网上完全探测不到这个服务**
- `[workspace]`:共享名,Windows 端访问 `\\100.x.y.z\workspace` 时的名字
- `path`:共享的实际目录,按你服务器上的真实路径调整
- `read only = no`:允许写入(拖文件进去)
- `valid users = davis`:只有 davis 账号可访问

```bash
sudo smbpasswd -a davis       # 给 davis 设置 SMB 专用密码(独立于系统密码,别复用)
sudo testparm -s              # 语法校验:输出配置且无 ERROR 即通过
sudo systemctl restart smbd   # 重启 samba 服务使配置生效
sudo systemctl enable smbd    # 确保开机自启
```

### 6.2 Windows 端映射

1. 资源管理器 → **此电脑** → 顶部菜单 `...` → **映射网络驱动器**
2. 驱动器选个字母(如 `W:`),文件夹填 `\\100.x.y.z\workspace`
3. 勾选 **登录时重新连接**;勾选 **使用其他凭据连接**
4. 弹窗中用户名填 `davis`,密码填刚才 `smbpasswd` 设的密码,勾选记住
5. 完成——`W:` 盘就是服务器上的 workspace,拖拽、双击、右键另存为全部照常

从此给 AI 传图片/设计稿 = 拖进 `W:\你的项目\_inbox\`,对话里说"看一下 `_inbox/design.png`"。

### 6.3 注意事项

- 你和容器里的 agent 在读写同一目录:素材文件随便拖,零冲突;但避免和 agent **同时编辑同一个代码文件**
- Windows 睡眠唤醒后盘符偶尔显示断开,双击它会自动重连(Tailscale 开机自启,通道一直在)

## 七、接入后日常方式的变化

| 事项 | 原来(经跳板) | 现在(直连) |
|---|---|---|
| SSH 登录 | Tabby + jump host | `ssh davis@100.x.y.z` 或 Tabby 直连 profile |
| 传文件 | Tabby SFTP 面板 | 直接拖进 `W:` 盘 |
| 看 dev server | 跳板隧道 | `ssh -L 5173:localhost:5173 davis@100.x.y.z`,一条命令 |
| Codex 登录转发 | 跳板隧道 | `ssh -L 1455:localhost:1455 davis@100.x.y.z` |
| VS Code Remote-SSH | 要配 ProxyJump | Host 直接填 100.x.y.z |
| 沙箱容器 | —— | **零改动**,这一切只改变你连服务器的方式 |

跳板机通道不必删除,留作 Tailscale 万一故障时的备用入口。

## 八、安全加固

按优先级:

1. **SSO 账号开 MFA**(第二步已做,再次强调:这是命门)
2. **收紧 ACL**:管理台 → Access Controls。默认规则是 tailnet 内全放行;改成只允许你的设备访问服务器的必要端口:

```jsonc
{
  "acls": [
    // 允许我的所有设备,访问服务器(把 IP 换成你服务器的 tailnet IP)的 SSH 和 SMB
    { "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["100.x.y.z:22", "100.x.y.z:445"] }
  ]
}
```

3. **Device approval**:管理台 → Settings → Device management → 开启 Manually approve new devices,新设备加入需你手动批准
4. **保持更新**:服务器上定期 `sudo tailscale update`;Windows 端客户端自动提示更新
5. 长期不用的设备在管理台及时 Remove
6. 更高要求可研究 **Tailnet Lock**(新节点须由既有节点签名,防控制面被攻破后塞入恶意设备),个人场景可选

## 九、故障排查

| 现象 | 处理 |
|---|---|
| `ping 100.x.y.z` 不通 | 两端托盘/`tailscale status` 确认都在线;服务器 `sudo systemctl restart tailscaled` |
| SSH 突然连不上(几个月后) | 多半是密钥过期——去管理台看设备是否 Expired,重新 `sudo tailscale up`;并按第五节关闭过期 |
| 映射盘提示找不到网络路径 | 先 `ping 100.x.y.z`;通则服务器上 `sudo ss -tlnp | grep 445` 看 smbd 是否监听在 tailnet IP 上——若只有 127.0.0.1,检查 interfaces 是否写成了网卡名(要写 IP),改后重启 smbd |
| 映射盘密码总不对 | SMB 密码是 `smbpasswd` 设的那个,不是系统登录密码;重设:`sudo smbpasswd -a davis` |
| 传输很慢 | `tailscale ping 100.x.y.z` 看是否走 relay;多数网络环境几分钟后会自动升级为 direct |
| 想暂时下线 | 服务器 `sudo tailscale down`(重新上线 `sudo tailscale up`);Windows 托盘里 Disconnect |
| 想彻底移除 | 管理台删除设备 + 服务器 `sudo apt remove tailscale` |
