# AI Agent 安全沙箱 —— Ubuntu 24.04 操作指引

在远程 Ubuntu 24.04 云主机上搭建一个隔离的 Docker 沙箱,让 Claude Code、Codex 等 AI 编码 agent 无人值守地工作,同时把它们与宿主机上的其它服务、凭证、网络严格隔离。

## 目录

1. [架构与安全模型](#一架构与安全模型)
2. [SSH:从 root+密码迁移到密钥登录](#二ssh从-root密码迁移到密钥登录)
3. [专用用户与 Docker 安装](#三专用用户与-docker-安装)
4. [构建并启动沙箱](#四构建并启动沙箱)
5. [登录各 AI Agent](#五登录各-ai-agent)
6. [日常使用](#六日常使用)
7. [GitHub Token 权限配置](#七github-token-权限配置)
8. [前端项目:浏览器测试与本地预览](#八前端项目浏览器测试与本地预览)
9. [向沙箱传文件(图片/设计稿/文档)](#九向沙箱传文件)
10. [可选:Tailscale 直连 + 挂载工作盘](#十可选tailscale-直连--挂载工作盘)
11. [新增一个 AI Agent 的标准流程](#十一新增一个-ai-agent-的标准流程)
12. [防火墙维护与故障排查](#十二防火墙维护与故障排查)
13. [安全边界:能防什么、不能防什么](#十三安全边界)

## 一、架构与安全模型

```
你的 Windows 11(Tabby / VS Code / 浏览器)
        │  SSH(密钥,经跳板机;或 Tailscale 直连)
        ▼
云主机 Ubuntu 24.04
  ├── 你的其它服务(不受影响,与沙箱无任何交集)
  └── davis:管理 + AI 工作用户(sudo)
        └── Docker 容器 ai-agents
              ├── node 用户(非 root)运行 claude / codex
              ├── 出站防火墙:默认全拒,白名单放行
              └── /workspace ← 只挂载项目代码目录
```

四层隔离,由内向外:

1. **容器内**:agent 以非 root 的 `node` 用户运行,sudo 只能执行防火墙脚本一个命令。
2. **容器网络**:默认拒绝一切出站,只放行 Anthropic/OpenAI/npm/Go/GitHub 白名单。恶意依赖包想外传数据,绝大多数通道是死的。
3. **挂载边界**:容器只能看见 `workspace/` 项目目录和自己的配置 volume,宿主机其它一切不可见。
4. **宿主机**:沙箱及 workspace 集中在 `davis` 名下的单一目录,与其它服务的文件互不纠缠。单用户方案比"管理/AI 分开两个账号"少一层隔离,换来管理简单;代价是 davis 的登录凭证成为关键资产——必须仅限密钥登录、私钥加口令。

本文所有 `#` 后的文字都是该行命令的用途说明。

### 每一节的命令由谁、在哪里执行

| 章节 | 在哪执行 | 以什么身份 |
|---|---|---|
| 2.1 生成密钥 | 本地 Windows PowerShell | 你本人 |
| 2.2–2.3 装公钥、关密码 | 服务器 | **root**(全流程唯一一次用 root) |
| 三 系统更新、Docker、docker 组 | 服务器 | **davis**(命令内已带 sudo) |
| 四 构建启动 / 五 登录 / 六 日常 | 服务器 | **davis**(无需 sudo) |
| 5.2 Codex 隧道、八③ 隧道、九 传文件 | 本地 Windows | 你本人 |
| 十 服务器端 | 服务器 | **davis**(命令内已带 sudo) |
| 十 Windows 端 | 本地 Windows | 你本人 |
| `docker compose exec ai-agents ...` 之后的命令 | 容器内 | 容器的 node 用户(自动) |

## 二、SSH:从 root+密码迁移到密钥登录

密码认证是整套方案最薄弱的环节,先补上。**顺序执行,防止把自己锁在门外。**

### 2.1 本地生成密钥(Windows PowerShell)

```powershell
ssh-keygen -t ed25519                        # 生成 ed25519 密钥对,一路回车;建议给私钥设个口令
type $env:USERPROFILE\.ssh\id_ed25519.pub    # 显示公钥内容,整行复制备用
```

### 2.2 服务器上创建用户并安装公钥

用现在的 root 登录操作,**这个会话全程保持打开**(它是出问题时的后悔药):

```bash
adduser davis                                # 创建日常管理用户(名字自定),按提示设密码
usermod -aG sudo davis                       # 加入 sudo 组,使其可执行管理命令
mkdir -p /home/davis/.ssh                    # 创建 SSH 配置目录
echo '粘贴你的公钥内容' > /home/davis/.ssh/authorized_keys   # 写入公钥(注意用单引号包住)
chmod 700 /home/davis/.ssh                   # 目录权限 700,sshd 要求严格权限否则拒用
chmod 600 /home/davis/.ssh/authorized_keys   # 文件权限 600,同上
chown -R davis:davis /home/davis/.ssh        # 属主改为 davis,root 建的文件默认属 root
```

### 2.3 验证后关闭密码登录

Tabby 中新建连接:认证方式选"私钥文件"→ 选中 `id_ed25519`。确认 `davis` 能登录且 `sudo -i` 正常后,**才**回到 root 会话执行:

```bash
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config   # 全局禁用密码认证
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config                 # 禁止 root 直接登录
systemctl restart ssh                        # 重启 sshd 使配置生效;已有会话不会断开
```

新开连接再次验证 davis 登录正常、root 和密码方式已失效,然后才退出旧 root 会话。

### 2.4 多设备登录

`authorized_keys` 一行一把公钥,数量不限;私钥配得上任意一行即可登录。推荐每台设备一把钥匙:

```bash
# 新设备上生成自己的密钥对(-C 注释用于辨认设备)
ssh-keygen -t ed25519 -C "office-pc"
# 在服务器上追加新设备的公钥(>> 是追加,千万别用 > 覆盖)
echo '新设备的公钥内容' >> ~/.ssh/authorized_keys
```

撤销某台设备 = 删掉 `authorized_keys` 里对应那行,立即生效。私钥文件也可以直接复制到其它机器使用,但泄漏面随副本数增大且无法按设备撤销,若这样做私钥必须设口令。

## 三、专用用户与 Docker 安装

以 `davis` 登录执行本节。

### 3.1 系统更新与自动安全补丁

```bash
sudo apt update                              # 刷新软件包索引
sudo apt full-upgrade -y                     # 升级所有已装包(含内核);刚升完 24.04 也跑一次收尾
sudo apt install -y unattended-upgrades      # 安装自动安全更新组件
sudo dpkg-reconfigure -plow unattended-upgrades   # 按提示选 Yes,启用每日自动安全补丁
```

### 3.2 安装 Docker(24.04 官方源)

```bash
sudo iptables-save | sudo tee /root/iptables-backup-$(date +%F).rules   # 备份现有防火墙规则(Docker 会加自己的链)
sudo install -m 0755 -d /etc/apt/keyrings    # 创建 apt 密钥环目录(不存在则建,权限 755)
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                                             # 下载 Docker 官方 GPG 公钥并转成 apt 可用格式
sudo chmod a+r /etc/apt/keyrings/docker.gpg  # 公钥对所有用户可读,否则 apt 报权限错误
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
                                             # 添加 Docker 的 noble(24.04)软件源,并指定用上面的公钥验签
sudo apt update                              # 刷新索引,让新源生效
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                                             # 依次为:Docker 引擎、命令行、容器运行时、构建插件、compose 插件
sudo docker run --rm hello-world             # 冒烟测试:能拉取并运行说明安装成功
```

说明:Docker 安装会在宿主机新增 DOCKER/FORWARD iptables 链,但不改 INPUT 链,普通监听端口的服务不受影响;装完确认现有服务正常再继续。

### 3.3 把 davis 加入 docker 组

```bash
sudo usermod -aG docker davis                # 加入 docker 组,之后管理容器不用 sudo
newgrp docker                                # 组变更在当前会话立即生效(或退出重登)
docker ps                                    # 验证:能输出容器列表(空表也算成功)即生效
```

**必须知道**:docker 组成员等价于 root(可通过挂载宿主目录提权)。davis 本就有 sudo,这一步并未额外扩大其权限;要守住的是 davis 的登录凭证本身——仅限密钥登录、私钥设口令。本方案未把 docker.sock 挂进容器,容器内的 agent 无法操作宿主 Docker,"AI 失控提权"这条路径是关闭的。

## 四、构建并启动沙箱

仍以 `davis` 执行本节及以后各节。

```bash
# 把本目录(remote-agent/)上传到服务器,例如本地 PowerShell 执行:
#   scp -r D:\home\ai\remote-agent davis@服务器:~/
cd ~/remote-agent                            # 进入沙箱配置目录

mkdir -p workspace                           # 创建项目代码目录(容器只能看见这里面)
# 把项目克隆进去,例如:
#   cd workspace && git clone https://github.com/你/仓库.git && cd ..

printf "HOST_UID=%s\nHOST_GID=%s\n" "$(id -u)" "$(id -g)" > .env
                                             # 记录 davis 的 UID/GID 到 .env,
                                             # 构建时容器内 node 用户会对齐成同样的 UID,
                                             # 保证挂载目录内外读写权限一致

docker compose up -d --build                 # 构建镜像并后台启动容器(首次约几分钟)
docker compose logs -f                       # 跟踪启动日志;看到下面两行说明防火墙已生效:
                                             #   OK: example.com blocked
                                             #   OK: api.github.com reachable
                                             # Ctrl+C 退出日志查看,不影响容器运行
```

## 五、登录各 AI Agent

登录凭证保存在 volume(claude-config / codex-config)里,重建容器不用重登。

### 5.1 Claude Code(订阅账号)

```bash
docker compose exec ai-agents claude         # 进入容器并启动 claude,首次会进入登录流程
```

选择订阅账号登录 → 终端显示一个 URL → 复制到**本地电脑**浏览器打开并授权 → 把返回的 code 粘贴回终端。

### 5.2 Codex(ChatGPT 订阅)

Codex 登录要在容器的 1455 端口做 OAuth 回调,需要一条本地到服务器的端口转发:

```powershell
ssh -L 1455:localhost:1455 davis@服务器      # 本地 PowerShell 执行,窗口保持打开
```

同时 docker-compose.yml 里临时加一行端口映射 `"127.0.0.1:1455:1455"`(登录完可删掉):

```bash
docker compose up -d                         # 应用端口映射改动
docker compose exec ai-agents codex          # 启动 codex,按提示在本地浏览器完成登录
```

### 5.3 API Key 方式(两家通用,适合无人值守)

编辑 `.env` 追加 `ANTHROPIC_API_KEY=sk-...` 或 `OPENAI_API_KEY=sk-...`,再取消 docker-compose.yml 中 environment 对应行的注释,`docker compose up -d` 生效。

## 六、日常使用

```bash
docker compose exec ai-agents bash           # 进入容器的 shell
tmux new -A -s work                          # 进入(或恢复)名为 work 的 tmux 会话:
                                             # SSH 断线后 agent 继续跑,重连后此命令原样恢复现场
cd /workspace/你的项目                        # 进入项目目录
claude --dangerously-skip-permissions        # 启动 Claude 并跳过逐条操作确认
                                             # (正因为有沙箱+防火墙,才能放心开这个开关)
# 或
codex                                        # 启动 Codex
```

tmux 最小用法:`Ctrl+B` 松开再按 `D` = 挂起离开(agent 继续跑);重进容器后 `tmux new -A -s work` 恢复。

### tmux 会话保存与恢复(docker 重建也不丢)

容器内置 `tmux-session` 工具,把当前所有会话/窗口/工作目录存成一份存档;该存档软链到命名卷 `tmux-data`,所以 `docker compose up -d --build` 重建后依然在。

```bash
tmux-session save        # 保存当前会话列表(结构变化时也会自动保存,见 tmux.conf 钩子)
tmux-session restore     # 重建/重启后,一条命令恢复所有会话、窗口和各自的目录
```

- **自动保存**:`tmux.conf` 里挂了钩子,新建窗口 / 关闭 pane / 重命名窗口时自动 `save`,通常不用手动存。
- **重建流程**:`docker compose up -d --build` → `docker compose exec ai-agents bash` → `tmux-session restore`。
- **恢复范围**:会话名、窗口名、每个窗口的工作目录(cwd 需仍存在,通常在 `/workspace` 下,持久)。**不恢复** pane 内正在跑的程序(如 claude 进程本身)——恢复的是布局和目录,进到目录后重新起 agent 即可。
- 存档在卷里,查看:`docker compose exec ai-agents cat /home/node/.tmux-session`。

**常用命令别名**:仓库里的 `host-aliases.sh` 汇总了 host 端管理容器的一行简写(进容器、起 agent、重建、加白名单、tmux 存档等,均带注释)。一次性装好:

```bash
cat ~/ai-agents/host-aliases.sh >> ~/.bashrc && source ~/.bashrc
```

之后常用:`ai`(进容器)、`aic`(起 Claude)、`ai-build`(重建)、`ai-logs`(看日志)、`fw-add x.com`(加白名单)、`ai-save`/`ai-restore`(tmux 会话)。容器**内部**的 `claude`、`ll`、`approve-push`、`wf-protect` 已在容器自身 bashrc,无需重复。

其它常用命令:

```bash
docker compose restart                       # 重启容器(同时重建防火墙规则)
docker compose down                          # 停止并删除容器(volume 保留,登录态不丢)
docker compose up -d --build                 # 改过 Dockerfile/防火墙脚本后重建
docker compose logs -f                       # 查看容器日志
```

## 七、GitHub Token 权限配置

用 **fine-grained token**,不用 classic(classic 的 repo scope 是全账号仓库权限,泄漏损失太大)。

创建:GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate new token,关键三项:

1. **Repository access**:Only select repositories,只勾 AI 要操作的仓库
2. **Repository permissions**:Contents = Read and write(clone/pull/push);需要 AI 建 PR 再加 Pull requests = Read and write;其余一律 No access
3. **Expiration**:30~90 天

容器里配置:

```bash
docker compose exec ai-agents bash           # 进入容器
git config --global user.name  "你的名字"     # 提交身份
git config --global user.email "you@example.com"
git config --global credential.helper store  # 让 git 记住凭证
git clone https://github.com/你/仓库.git      # 首次操作时:用户名填 GitHub 用户名,密码粘贴 token
```

**凭证持久化**:`~/.gitconfig` 与 `~/.git-credentials` 已软链到命名卷 `git-config`,所以上面这些配置和 token **重建容器也不丢**,只需首次设置一次。注意 token 在 `~/.git-credentials` 里是明文(和标准 git 一样),该卷在服务器上、仅 root/davis 可及。

更稳的玩法:token 只给 Contents = Read(AI 只能 pull),改动由你在宿主机审查后手动 push。

## 八、前端项目:浏览器测试与本地预览

**AI 自动测试**:镜像已内置 Playwright + Chromium(headless),`npx playwright test`、截图、E2E 直接可用。也可以直接吩咐 agent:"用 Playwright 打开 localhost:5173 截图,检查布局"——它自己截自己看,不需要你传图。

**你自己在本地浏览器看页面**,三步:

```bash
# ① 容器内启动 dev server 时必须监听 0.0.0.0(默认监听 localhost 时 Docker 映射不到):
npm run dev -- --host 0.0.0.0                # Vite;其它框架找 --host 或 host 配置项
```

② 取消 docker-compose.yml 中 ports 段注释(`127.0.0.1:5173:5173`,只绑服务器回环,公网不可达),`docker compose up -d` 生效。服务器上 `curl localhost:5173` 有响应即通。

③ 本地建 SSH 隧道后浏览器打开 `http://localhost:5173`:

- **Tabby**:编辑服务器 profile → 端口转发 → 新增 Local 类型,本地 5173 → 目标 localhost:5173,重连生效(跳板机自动穿透);或在已连接标签页的端口转发图标里临时添加。
- **命令行**:`C:\Users\你\.ssh\config` 写入以下内容后,PowerShell 执行 `ssh devbox`:

```
Host jump
    HostName 跳板机IP
    User 跳板机用户名

Host devbox
    HostName 服务器IP
    User davis
    ProxyJump jump                # 经 jump 中转连接
    LocalForward 5173 localhost:5173   # 建立隧道:本地5173 → 服务器5173
```

配好这份 config 后,VS Code Remote-SSH 也能直接连 `devbox`(自动走跳板、自动转发端口)。

## 九、向沙箱传文件

原则:**文件放进 `workspace/`,对话里用路径引用**(容器只能看见挂载目录)。

- **Tabby SFTP**(最顺手):连接后点标签页工具栏的 SFTP 按钮,从 Windows 直接拖文件到 `~/remote-agent/workspace/项目/_inbox/` 之类的约定目录。
- **VS Code Remote-SSH**:文件直接拖进左侧文件树。
- **命令行**:`scp 本地文件.png devbox:~/remote-agent/workspace/项目/_inbox/`(用第八节的 ssh config)。

对话中引用:Claude Code 里输入 `@` 可补全文件路径,或直接说"看一下 `_inbox/design.png`"。png/jpg/pdf/代码/csv 都能直接读。

## 十、可选:Tailscale 直连 + 挂载工作盘

绕过跳板机直连服务器、把 workspace 挂成 Windows 盘符。若跳板机是公司合规要求,启用前先与运维确认。

> **零基础详细教程见同目录《Tailscale使用指南.md》**(含注册、两端安装、密钥过期设置、ACL 加固、故障排查),本节只保留命令速查。

### 服务器端

```bash
curl -fsSL https://tailscale.com/install.sh | sh   # 官方脚本安装 Tailscale
sudo tailscale up                            # 加入你的 tailnet,按提示用浏览器授权
tailscale ip -4                              # 查看本机的 tailnet IP(100.x.y.z),记下来

sudo apt install -y samba                    # 安装 SMB 文件共享服务
sudo tee -a /etc/samba/smb.conf <<'EOF'      # 向 samba 配置追加以下内容(EOF 之间原样写入)

[global]
   interfaces = lo 100.x.y.z
   bind interfaces only = yes

[workspace]
   path = /home/davis/remote-agent/workspace
   read only = no
   valid users = davis
EOF
# ↑ interfaces:100.x.y.z 换成你的 tailnet IP;要写 IP 而非网卡名 tailscale0(P2P /32 接口按名字常识别不到)
# ↑ bind interfaces only:严格只绑上述地址,公网不可达
# ↑ [workspace] 共享段:路径、可写、仅允许 davis 账号访问
sudo smbpasswd -a davis                      # 给 davis 设置 SMB 专用密码(别复用登录密码)
sudo testparm -s                             # 校验 samba 配置语法,无报错再继续
sudo systemctl restart smbd                  # 重启 samba 使配置生效
```

### Windows 端

1. 安装 Tailscale 客户端,登录同一账号
2. 资源管理器 → 此电脑 → 映射网络驱动器 → `\\100.x.y.z\workspace`,输入 davis 的 SMB 密码
3. SSH/scp 也可直连了:`ssh davis@100.x.y.z`,不再需要跳板

### 安全加固

- Tailscale 登录用的 SSO 账号**必须开 MFA**——tailnet 的边界就是这个账号
- 管理台 Access Controls 收紧 ACL:只允许你的设备访问这台服务器的 22/445 端口
- 开启 Device approval;`tailscale update` 保持更新;在意控制面风险可开 Tailnet Lock

## 十点五、可选:规范开发流程(dev-workflow)

给容器内的 Claude Code 装一套开发纪律:先理解需求 → 分析 / 定位根因 → 你审核 → 拉分支开发 → 自检 → `/ship` 交付待审,由你确认后再推送 / 合并。靠"全局 CLAUDE.md(软约定)+ git-guard 钩子拦截 push/merge/主分支提交 + 可选 git 原生 pre-push 硬后盾"落地。

安装(容器内一次即可,配置进 `~/.claude` 持久化):

```bash
docker compose cp dev-workflow ai-agents:/tmp/dev-workflow   # 拷进容器
docker compose exec ai-agents bash /tmp/dev-workflow/install.sh   # 安装
```

详见 **dev-workflow/README.md**(含日常用法、`/spec` `/bugfix` `/ship` 命令、`approve-push` / `wf-protect`、以及安全边界说明)。

## 十一、新增一个 AI Agent 的标准流程

以后要加任何新 agent(例如 Gemini CLI),固定三步:

1. **Dockerfile**:"安装各家 AI Agent"区块加一行安装命令,例如 `RUN npm install -g @google/gemini-cli`
2. **init-firewall.sh**:`ALLOWED_DOMAINS` 数组加该 agent 的 API 与登录域名(查其文档,通常报错信息里也会显示被拦的域名)
3. **docker-compose.yml**:若它有自己的配置目录(如 `~/.gemini`),照现有模式加一行 volume 持久化登录态

然后重建:

```bash
docker compose up -d --build                 # 重新构建镜像并替换容器
docker compose logs -f                       # 确认防火墙自检通过
```

## 十二、防火墙维护与故障排查

| 现象 | 原因与处理 |
|---|---|
| 某白名单域名突然不通 | CDN 换了 IP,`docker compose restart` 重建规则即可 |
| agent 报某域名连不上 | 该域名不在白名单;加进 `ALLOWED_DOMAINS` 后 restart |
| 启动日志报 `WARN: Failed to resolve xxx, skipping` | 该域名当前解析不到(下线或 DNS 波动),已自动跳过,不影响启动;若是你新加的域名,检查拼写 |
| 容器内新文件宿主机没权限 | `.env` 的 HOST_UID 未对齐,重新生成 .env 并 `up -d --build` |
| 页面加载外部字体/JS 失败 | 属正常拦截;需要就把对应 CDN 域名加白名单 |
| 依赖下载/第三方 API 连不上 | 用 `fw allow <域名>` 即时放行(见十二点五节),无需重建 |
| CDN 类域名(jsdelivr/cloudflare/AWS)时通时断 | IP 轮换所致:`fw reload` 重新解析;频繁抖动则改用 SNI 过滤代理按域名放行 |
| `fw reload` 后**所有**域名(含 github)都连不上 | 旧版脚本的陷阱:reload 中途被 Ctrl-C / github 抓取失败,留下"默认拒绝且无放行规则"。恢复(host 上):`docker compose exec -u root ai-agents iptables -P OUTPUT ACCEPT` 再 `docker compose exec -u root ai-agents /usr/local/bin/init-firewall.sh`。新版脚本已修复(flush 后重置策略为 ACCEPT),重建一次即可根治 |

## 十二点五、动态增删白名单(无需 rebuild)

白名单分两部分:`init-firewall.sh` 里烤进镜像的**基础域名**(改这些仍需重建),以及 `firewall/allowlist.txt` 这个 **bind-mount 的动态文件**(随时增删、`fw reload` 立即生效)。

本方案采用 **host-only 只读挂载**(`:ro`):`allowlist.txt` **只能由你在 host(服务器)上编辑**,容器内的 AI / 依赖无法修改它——这样即便容器内某个进程想偷偷放行外传通道也做不到。容器内 `fw allow` 仍可**临时**放行(重启即失效),持久放行必须走 host。

> **关于通配符**:`*.google.com` 这类写法**无效**——防火墙靠 DNS 把域名解析成 IP,而通配符没法解析。只能逐个列出实际用到的子域名(基础白名单里已内置 Google/GitHub 等一批常用具名域名)。真需要按域名整段放行,得改用 SNI 过滤代理。另外,放行 `google.com` 不等于能用 Google 搜索浏览全网——搜索结果指向的其它域名仍会被拦;要广泛浏览网页得走开放外网或代理方案。

### 添加一个域名(快速,秒级 —— 推荐)

`fw allow` 只解析你要加的域名并 `ipset add`,**不抓 GitHub、不重解析其它域名**,一秒生效。持久化把域名追加到 host 的 allowlist 文件即可(下次重建/重启仍在):

```bash
cd ~/ai-agents
echo "test.anewstip.com" >> firewall/allowlist.txt              # 持久化(供以后重建加载)
docker compose exec ai-agents fw allow test.anewstip.com        # 即时生效(秒级,不用 reload)
```

**建议**:把下面这个函数加到服务器上 davis 的 `~/.bashrc`,以后一行搞定(持久化 + 即时生效):

```bash
fw-add() {
  local f=~/ai-agents/firewall/allowlist.txt
  for d in "$@"; do grep -qxF "$d" "$f" 2>/dev/null || echo "$d" >> "$f"; done
  docker compose -f ~/ai-agents/docker-compose.yml exec ai-agents fw allow "$@"
}
# 用法:fw-add test.anewstip.com   或   fw-add a.com b.com 1.2.3.4
```

### 什么时候才需要 fw reload(慢,少用)

`fw reload` 会重跑整个防火墙脚本(重抓 GitHub IP + 全量重解析),**只在这些情况用**:你从 allowlist 文件里**删除**了条目要生效、或**批量**改了很多行想整体重来。**注意别在它跑到一半时 Ctrl-C**——会停在"设默认拒绝"之前,导致防火墙暂时全放行;让它跑完。

- 查看当前放行:`docker compose exec ai-agents fw list`。
- 文件在 host 上,只读挂载,容器内改不了;持久化一律在 host 追加。

### 放行 AWS 服务(按 IP 段)

`*.amazonaws.com` 这类通配没法用 DNS 放行,但 AWS **官方发布 IP 段清单**,可整段放行。由 host 上的 `firewall/aws-allow.txt` 控制,每行一个,编辑后 `fw reload` 生效:

```text
S3:us-west-2      # 某服务 + 指定区域(范围小,推荐)
CLOUDFRONT        # 某服务全区域(服务名大写)
ALL               # AWS 全部服务(≈整个 AWS,含所有 EC2 客户主机,慎用)
```

```bash
# 服务器上:编辑后重载(AWS 段需重新抓 ip-ranges.json,走 fw reload)
nano ~/ai-agents/firewall/aws-allow.txt
docker compose exec ai-agents fw reload
```

**安全提醒**:`ALL` 会把几乎整个 AWS 网段加进白名单——任何人租一台 EC2 就落在里面,数据外传防护大幅削弱。强烈建议只放你真正用到的服务/区域(如 `S3:us-west-2`),而不是 `ALL`。常见服务名:`S3` `EC2` `CLOUDFRONT` `API_GATEWAY` `DYNAMODB` `ROUTE53`。

### 放行 Google / GCP 服务(按 IP 段)

Google **不按产品**发布 IP 段(没有"只有 BigQuery"的范围),但发布了整体清单。由 `firewall/gcp-allow.txt` 控制,每行一个关键字,`fw reload` 生效:

```text
APIS              # Google 自有服务全段(goog.json 减 cloud.json)= 所有 googleapis(含 BigQuery/Vertex/GCS),不含客户 GCP 虚机 —— 给 Google API 用最合适
GOOG              # goog.json 全部(所有 Google 自有 IP,更大)
CLOUD:us-central1 # cloud.json 某区域客户网段(连别人的 GCE 实例才用)
```

```bash
echo "APIS" >> ~/ai-agents/firewall/gcp-allow.txt
docker compose exec ai-agents fw reload
```

用 `APIS` 就能让 BigQuery(及所有 googleapis 端点)稳定可达,不受域名 IP 轮换影响,范围也仅限 Google 自有服务、不含客户虚机。

### 检测域名是否可访问

```bash
docker compose exec ai-agents fw-check api.stripe.com github.com   # 一键检测,区分失败原因
```

输出会告诉你是哪种情况:✅ 可访问 / ⛔ 被防火墙拦截(不在白名单,附放行命令)/ ⚠️ 在白名单但对方不通 / ❌ 域名解析失败。手动测也行:

```bash
docker compose exec ai-agents curl -sS -o /dev/null -w "%{http_code}\n" --connect-timeout 5 https://api.stripe.com
# 000 = 连不上(多为被拦);200/401/403 等 = 网络已通(对方在应答)
```

注意:切换到 `:ro` 以及首次安装 `fw` 机制,需要**重建一次**容器(`docker compose up -d --build`);之后增删域名只需"编辑文件 + fw reload",不用再 compose。
| 想看当前生效规则 | 容器内执行 `sudo ipset list allowed-domains` 与 `sudo iptables -L -n`(提示无权限属正常,sudoers 只放行了防火墙脚本;可 `docker exec -u root ai-agents iptables -L -n`) |

## 十三、安全边界

**这套方案防得住**:agent 误删宿主机文件(看不见)、恶意依赖包外传数据(网络白名单)、agent 提权(非 root + 无 docker.sock)、凭证大面积泄漏(容器里只有范围受限的 GitHub token 和 agent 自身凭证)。

**防不住,要靠习惯**:

- 挂进 workspace 的东西 agent 全能读写——别把生产密钥、.env 秘密文件放进去
- 恶意代码库仍可利用**白名单内**的域名(如 GitHub)外传容器内可见的内容——`--dangerously-skip-permissions` 只用于你信任的仓库
- GitHub token 永远最小权限、短有效期
- agent 写的代码上生产前,过一遍你自己的眼睛
