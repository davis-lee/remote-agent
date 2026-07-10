#!/usr/bin/env bash
# 在 ai-agents 容器内安装 dev-workflow。幂等,可重复运行。
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

mkdir -p "$DEST/commands" "$DEST/hooks" "$DEST/git-hooks"

cp "$SRC/CLAUDE.md"              "$DEST/CLAUDE.md"
cp "$SRC"/commands/*.md          "$DEST/commands/"
cp "$SRC/hooks/git-guard.sh"     "$DEST/hooks/";     chmod +x "$DEST/hooks/git-guard.sh"
cp "$SRC/git-hooks/pre-push"     "$DEST/git-hooks/"; chmod +x "$DEST/git-hooks/pre-push"

# 合并 hooks 配置到 settings.json(已存在则深合并,不覆盖其它键)
if [ -f "$DEST/settings.json" ]; then
  tmp=$(mktemp)
  jq -s '.[0] * .[1]' "$DEST/settings.json" "$SRC/settings.json" > "$tmp" && mv "$tmp" "$DEST/settings.json"
else
  cp "$SRC/settings.json" "$DEST/settings.json"
fi

# 安装便捷函数到 .bashrc(幂等)
BRC="$HOME/.bashrc"
if ! grep -q 'dev-workflow helpers' "$BRC" 2>/dev/null; then
  cat >> "$BRC" <<'EOF'

# --- dev-workflow helpers ---
approve-push() { HUMAN_PUSH=1 git push "$@"; }   # 人工批准并推送
wf-protect() {                                    # 在当前仓库安装 push 硬后盾
  local root; root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "不在 git 仓库内"; return 1; }
  cp "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/git-hooks/pre-push" "$root/.git/hooks/pre-push"
  chmod +x "$root/.git/hooks/pre-push"
  echo "已安装 push 硬后盾到 $root(推送用 approve-push)"
}
# --- end dev-workflow helpers ---
EOF
fi

echo "✅ dev-workflow 已安装到 $DEST"
echo "   - 全局 CLAUDE.md、/spec /bugfix /ship 命令、git-guard PreToolUse 钩子已就位"
echo "   - 需要 push 硬后盾的仓库,进目录后运行一次: wf-protect"
echo "   - 新开 shell 后 approve-push / wf-protect 生效(或先 source ~/.bashrc)"
