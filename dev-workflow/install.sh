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

# git 模板:让以后每个新 clone / init 的仓库自动带上 pre-push 硬后盾
TPL="$HOME/.git-template"
mkdir -p "$TPL/hooks"
cp "$SRC/git-hooks/pre-push" "$TPL/hooks/pre-push"; chmod +x "$TPL/hooks/pre-push"
git config --global init.templateDir "$TPL"

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
echo "   - 新 clone / init 的仓库自动带 pre-push 硬后盾(git 模板已配置)"
echo "   - 已存在的仓库补钩子:进目录跑一次 git init(安全,不动代码历史);或 wf-protect"
echo "   - 新开 shell 后 approve-push / wf-protect 生效(或先 source ~/.bashrc)"
