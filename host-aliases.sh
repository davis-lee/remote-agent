# ============================================================
#  ai-agents 沙箱常用命令(host 端 / 服务器上 davis 使用)
#  安装:  cat ~/ai-agents/host-aliases.sh >> ~/.bashrc && source ~/.bashrc
#  之后在服务器任意目录都能用下面这些简写
# ============================================================

# 沙箱项目目录(如果你放在别处,改这一行)
export AIDIR=~/ai-agents

# docker compose 简写:带 -f 指定文件,任意目录可用,不必先 cd
alias dc='docker compose -f $AIDIR/docker-compose.yml'

# ---------- 进容器 / 起 agent ----------
alias ai='dc exec ai-agents bash'          # 进容器 shell
alias aiw='dc exec ai-agents tmux a'  # 进容器并attach tmux

# ---------- 容器生命周期 ----------
alias ai-build='dc up -d --build'          # 改过 Dockerfile/脚本后:重建并启动
alias ai-up='dc up -d'                     # 启动(不重建)
alias ai-down='dc down'                    # 停止并删除容器(命名卷/登录态保留)
alias ai-restart='dc restart'              # 重启容器(防火墙随之重建)
alias ai-logs='dc logs -f'                 # 跟踪容器日志(Ctrl+C 退出查看)
alias ai-ps='dc ps'                        # 查看容器状态

# ---------- 防火墙白名单 ----------
# 加域名/IP:持久化到 allowlist.txt(供以后重建)+ 容器内秒级生效(不用慢速 reload)
fw-add() {
  local f=$AIDIR/firewall/allowlist.txt
  for d in "$@"; do grep -qxF "$d" "$f" 2>/dev/null || echo "$d" >> "$f"; done
  dc exec ai-agents fw allow "$@"
}
alias fw-list='dc exec ai-agents fw list'          # 查看当前放行的 IP 集合
alias fw-check='dc exec ai-agents fw-check'        # 检测域名可达性,如: fw-check api.stripe.com
alias fw-reload='dc exec ai-agents fw reload'      # 全量重载(慢;仅删条目/批量改时用)

# ---------- tmux 会话保存 / 恢复(重建不丢)----------
alias ai-save='dc exec ai-agents tmux-session save'      # 保存当前会话列表
alias ai-restore='dc exec ai-agents tmux-session restore' # 重建/重启后恢复会话
# ============================================================
