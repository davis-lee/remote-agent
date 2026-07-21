#!/bin/bash
# 特权辅助脚本:仅能向 allowed-domains 集合"添加"条目,或列出集合。
# 由 sudoers 授权 node 免密执行(scope 极小:不能 flush/destroy,不能加别的规则)。
set -euo pipefail

# 列出当前放行集合
if [ "${1:-}" = "--list" ]; then
  ipset list allowed-domains
  exit 0
fi

# 逐个添加,只接受 IPv4 或 CIDR(域名解析在非特权侧完成后再传进来)
for entry in "$@"; do
  if [[ "$entry" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]]; then
    ipset add allowed-domains "$entry" 2>/dev/null || true
  else
    echo "拒绝非法条目(只接受 IP/CIDR):$entry" >&2
  fi
done
