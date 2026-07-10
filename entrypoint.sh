#!/bin/bash
# 容器入口脚本:先建防火墙,再执行 CMD(默认 sleep infinity 挂起等待)
set -e

# iptables 规则不跨重启保留,所以每次启动都重建
# sudoers 只授权了这一个命令,node 用户没有其它 root 权限
sudo /usr/local/bin/init-firewall.sh

echo "Sandbox ready. Attach with: docker compose exec ai-agents bash"
exec "$@"   # 用 exec 替换进程,让 CMD 成为 PID 1 的子进程,信号处理正确
