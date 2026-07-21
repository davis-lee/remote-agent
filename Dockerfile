# =============================================================================
# AI Agent 沙箱镜像
# 基础镜像 node:22-bookworm:Debian 12 + Node.js 22 LTS
# (claude / codex 都是 npm 包,选 node 官方镜像最省事;内置非 root 用户 node)
# =============================================================================
FROM node:22-bookworm

# 时区,可在 docker-compose.yml 里覆盖
ARG TZ=Asia/Shanghai
ENV TZ="$TZ"

# 各组件版本,构建时可用 --build-arg 覆盖
ARG CLAUDE_CODE_VERSION=latest
# 与当前工作环境保持一致;升级时改这里或构建时 --build-arg GO_VERSION=x.y.z 覆盖
ARG GO_VERSION=1.23.4

# -----------------------------------------------------------------------------
# 系统工具
#   git/gh          代码管理、GitHub CLI(建 PR 用)
#   sudo            仅授权 node 用户执行防火墙脚本(见文件末尾)
#   iptables/ipset  容器内防火墙
#   iproute2        提供 ip 命令(防火墙脚本探测宿主网段用)
#   dnsutils        提供 dig 命令(防火墙脚本解析白名单域名用)
#   aggregate       合并 GitHub 的 CIDR 段,减少防火墙条目
#   jq              解析 GitHub meta API 的 JSON
# -----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
  git gh less procps sudo unzip gnupg2 tmux \
  iptables ipset iproute2 dnsutils aggregate jq \
  nano vim curl wget ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# Go 工具链(官方 tarball 安装到 /usr/local/go)
# -----------------------------------------------------------------------------
RUN ARCH=$(dpkg --print-architecture) && \
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" -o /tmp/go.tgz && \
  tar -C /usr/local -xzf /tmp/go.tgz && \
  rm /tmp/go.tgz
ENV PATH=$PATH:/usr/local/go/bin:/home/node/go/bin

# -----------------------------------------------------------------------------
# 把容器内 node 用户的 UID/GID 对齐宿主机运行用户(davis)
# 否则挂载进来的 workspace 会出现"容器内没有写权限"的问题
# 值由 docker-compose.yml 从 .env 读入
# -----------------------------------------------------------------------------
ARG HOST_UID=1000
ARG HOST_GID=1000
RUN if [ "$HOST_UID" != "1000" ] || [ "$HOST_GID" != "1000" ]; then \
      groupmod -g "$HOST_GID" node && \
      usermod -u "$HOST_UID" -g "$HOST_GID" node && \
      chown -R node:node /home/node; \
    fi

# npm 全局安装目录归 node 用户,避免全局装包要 root
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R node:node /usr/local/share

# bash 历史写到 /commandhistory(compose 里挂了 volume,重建容器不丢历史)
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R node /commandhistory \
  && echo "$SNIPPET" >> /home/node/.bashrc \
  && echo "alias ll='ls -alF'" >> /home/node/.bashrc \
  && echo 'claude() { if [ "$#" -eq 0 ]; then command claude --remote-control "R-$(basename "$PWD")-$(date +%y%m%d%H)"; else command claude "$@"; fi; }' >> /home/node/.bashrc
# ↑ 无参启动 claude 时,会话名 = R-<当前目录名>-<YYMMDDHH>;tmux 配置见下方 COPY tmux.conf

# tmux 配置(含鼠标 + 自动保存会话钩子)
COPY --chown=node:node tmux.conf /home/node/.tmux.conf

# 标记环境变量,方便 agent 或脚本识别自己在沙箱里
ENV DEVCONTAINER=true

# /workspace 是项目代码的挂载点;各 agent 的配置目录提前建好并授权
# .tmux-data 是命名卷挂载点;把 tmux-session 的存档 ~/.tmux-session 软链进去,
# 这样 tmux-session save 写入的会话列表落在卷里,docker 重建也不丢
RUN mkdir -p /workspace /home/node/.claude /home/node/.codex /home/node/.tmux-data /home/node/.gitpersist && \
  ln -sf /home/node/.tmux-data/session /home/node/.tmux-session && \
  ln -sf /home/node/.gitpersist/gitconfig /home/node/.gitconfig && \
  ln -sf /home/node/.gitpersist/git-credentials /home/node/.git-credentials && \
  chown -R node:node /workspace /home/node/.claude /home/node/.codex /home/node/.tmux-data /home/node/.gitpersist && \
  chown -h node:node /home/node/.tmux-session /home/node/.gitconfig /home/node/.git-credentials
# ↑ ~/.gitconfig 与 ~/.git-credentials 软链到 .gitpersist 命名卷,
#   这样 git 配置和凭证(token)重建容器也不丢

WORKDIR /workspace

# 之后的操作以非 root 的 node 用户执行
USER node
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin
# Claude Code 的全部配置(含登录凭证)集中到这个目录,方便 volume 持久化
ENV CLAUDE_CONFIG_DIR=/home/node/.claude
ENV EDITOR=nano

# =============================================================================
# 安装各家 AI Agent —— 以后新增 agent 就在这里加一行,并做两件配套事:
#   1) init-firewall.sh 的 ALLOWED_DOMAINS 里加该 agent 的 API/登录域名
#   2) 若它有自己的配置目录,在 docker-compose.yml 加对应 volume 持久化登录态
# 示例(Gemini CLI):RUN npm install -g @google/gemini-cli
# =============================================================================
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}
RUN npm install -g @openai/codex

# -----------------------------------------------------------------------------
# Playwright:构建期装好 Chromium 及系统依赖
# (运行期防火墙默认挡浏览器下载,所以必须在构建期装)
# -----------------------------------------------------------------------------
USER root
RUN npx -y playwright install-deps chromium && \
  apt-get clean && rm -rf /var/lib/apt/lists/*
USER node
RUN npx -y playwright install chromium

# -----------------------------------------------------------------------------
# 防火墙脚本与入口脚本
# sudoers 只授权 node 用户免密执行 init-firewall.sh 这一个命令,
# 除此之外 node 没有任何 root 权限
# -----------------------------------------------------------------------------
COPY init-firewall.sh entrypoint.sh fw-allow.sh fw fw-check tmux-session /usr/local/bin/
USER root
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh \
             /usr/local/bin/fw-allow.sh /usr/local/bin/fw /usr/local/bin/fw-check \
             /usr/local/bin/tmux-session && \
  mkdir -p /etc/firewall && \
  # sudoers 只授权这两个脚本:重建防火墙、向白名单添加条目(不能 flush/destroy)
  printf 'node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh, /usr/local/bin/fw-allow.sh\n' > /etc/sudoers.d/node-firewall && \
  chmod 0440 /etc/sudoers.d/node-firewall

# tmux 等登录 shell 会重读 /etc/profile 导致 PATH 被重置,
# 用 profile.d 片段把 agent 和 Go 的路径补回来(所有登录 shell 自动加载)
RUN printf '%s\n' \
  'export PATH="$PATH:/usr/local/go/bin:/usr/local/share/npm-global/bin:/home/node/go/bin"' \
  'export CLAUDE_CONFIG_DIR=/home/node/.claude' \
  > /etc/profile.d/ai-agents.sh
USER node

# 容器启动:先建防火墙,再挂起等待(人通过 docker compose exec 进入使用)
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
