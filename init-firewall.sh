#!/bin/bash
# =============================================================================
# 容器内出站防火墙 —— 基于 anthropics/claude-code 官方 devcontainer 改编
# 策略:默认拒绝一切出站流量,仅放行下方白名单
# 作用范围:仅本容器的网络命名空间,不影响宿主机 iptables
# 执行时机:每次容器启动由 entrypoint.sh 调用(iptables 规则不跨重启保留)
# =============================================================================
set -euo pipefail          # 任一命令失败/未定义变量/管道出错即退出,防止半套规则生效
IFS=$'\n\t'                # 收紧分词规则,避免路径含空格时出错

# ===== 白名单域名 —— 新增 agent 或依赖时在这里加 =====
ALLOWED_DOMAINS=(
    # --- Anthropic / Claude Code(含订阅 OAuth 登录)---
    "api.anthropic.com"
    "claude.ai"
    "console.anthropic.com"
    "statsig.anthropic.com"
    "statsig.com"
    "sentry.io"
    # --- OpenAI / Codex(含 ChatGPT 订阅登录)---
    "api.openai.com"
    "auth.openai.com"
    "chatgpt.com"
    # --- 包管理:Node / Go ---
    "registry.npmjs.org"
    "proxy.golang.org"
    "sum.golang.org"
    "index.golang.org"
    # --- GitHub 静态资源(主站 CIDR 由下方 meta API 获取,这两个域名不在其中)---
    "raw.githubusercontent.com"
    "objects.githubusercontent.com"
    # --- Playwright 浏览器下载(项目锁定特定版本时运行期需要)---
    "cdn.playwright.dev"
    "playwright.download.prss.microsoft.com"
)

# 1) 保存 Docker 内部 DNS(127.0.0.11)的 NAT 规则,清空规则表后再恢复它
#    否则容器内域名解析会坏掉
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

iptables -F                # 清空 filter 表所有链的规则
iptables -X                # 删除自定义链
iptables -t nat -F         # 清空 nat 表
iptables -t nat -X
iptables -t mangle -F      # 清空 mangle 表
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true   # 删除旧 ipset(不存在则忽略)

if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat   # 逐条恢复 DNS NAT 规则
fi

# 2) 基础放行:域名解析、git over ssh、本地回环
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT      # 允许发出 DNS 查询
iptables -A INPUT -p udp --sport 53 -j ACCEPT       # 允许收到 DNS 应答
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT      # 允许出站 SSH(git@github.com)
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT  # SSH 回包
iptables -A INPUT -i lo -j ACCEPT                   # 回环入(dev server 自测要用)
iptables -A OUTPUT -o lo -j ACCEPT                  # 回环出

# 3) 建立 IP 白名单集合(hash:net 支持网段)
ipset create allowed-domains hash:net

# 3a) GitHub 主站:官方 meta API 返回其全部 CIDR 段,逐段校验格式后加入
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi
if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi
while read -r cidr; do
    # 正则校验,防止上游返回异常内容污染防火墙
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    ipset add allowed-domains "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)
# jq 取 web/api/git 三组 CIDR;aggregate 合并相邻网段减少条目

# 3b) 白名单域名:逐个 DNS 解析成 IP 加入集合
for domain in "${ALLOWED_DOMAINS[@]}"; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')  # 只取 A 记录
    if [ -z "$ips" ]; then
        # 解析失败降级为警告:个别域名下线或 DNS 波动不应让沙箱整体起不来。
        # 解析不到 = 拿不到 IP = 本来就处于被拦截状态,安全方向不变。
        echo "WARN: Failed to resolve $domain, skipping"
        continue
    fi
    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip"
            exit 1
        fi
        ipset add allowed-domains "$ip" 2>/dev/null || true   # 重复 IP 忽略
    done < <(echo "$ips")
done

# 4) 放行与宿主机所在网段的通信(端口映射的流量从这里进出)
HOST_IP=$(ip route | grep default | cut -d" " -f3)   # 默认网关 = Docker 网桥地址
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi
HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")   # 换算成 /24 网段
echo "Host network: $HOST_NETWORK"
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# 5) 收网:默认策略全部 DROP,再放行三类流量
iptables -P INPUT DROP     # 入站默认丢弃
iptables -P FORWARD DROP   # 转发默认丢弃(容器不做路由)
iptables -P OUTPUT DROP    # 出站默认丢弃 —— 白名单机制的核心
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT    # 已建立连接的回包
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT # 目标在白名单则放行
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited    # 其余直接拒绝(比静默丢弃报错更快)

# 6) 自检:白名单外的应不通,白名单内的应通
echo "Firewall configuration complete. Verifying..."
if curl --connect-timeout 5 -s https://example.com >/dev/null 2>&1; then
    echo "ERROR: Verification failed - able to reach https://example.com"
    exit 1
fi
echo "OK: example.com blocked"
if ! curl --connect-timeout 5 -s https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Verification failed - unable to reach https://api.github.com"
    exit 1
fi
echo "OK: api.github.com reachable"
