#!/usr/bin/env bash
# Claude Code PreToolUse 钩子:拦截危险 git 操作,让"我"始终是 main/推送的关卡。
# 输入:stdin 收到 Claude 传来的 JSON,含 .tool_input.command
# 放行:exit 0;拦截:exit 2(stderr 反馈给 Claude)
# 注意:bypass 模式下个别版本 hook 与命令有竞态,故另配 git 原生 pre-push 做硬后盾。

input=$(cat)

# 取出待执行命令;非 Bash 工具或空命令直接放行
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "${cmd:-}" ] && exit 0
cwd=$(printf '%s' "$input" | jq -r '.cwd // "."' 2>/dev/null)
[ -z "${cwd:-}" ] && cwd="."

# 折叠换行与多余空格,便于匹配
norm=$(printf '%s' "$cmd" | tr '\n' ' ' | tr -s ' ')

deny() {
  echo "⛔ dev-workflow 拦截:$1" >&2
  echo "不要重试、不要绕过、不要改用别的命令达到同样目的。" >&2
  echo "停下,展示 diff / 方案,等我明确批准。推送 / 合并由我本人执行。" >&2
  exit 2
}

echo "$norm" | grep -qE '\bgit +push\b'               && deny "禁止 git push(推送由我本人执行)"
echo "$norm" | grep -qE '\bgit +merge\b'             && deny "禁止 git merge(合并到 main 由我本人执行)"
echo "$norm" | grep -qE '\bgit +reset\b.*--hard'     && deny "禁止 git reset --hard(可能丢失改动)"
echo "$norm" | grep -qE '\bgit +branch +-D +(main|master)\b' && deny "禁止删除主分支"

# 保护分支上的直接提交
if echo "$norm" | grep -qE '\bgit +commit\b'; then
  branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  case "$branch" in
    main|master) deny "禁止在 '$branch' 上直接提交,请先拉功能分支" ;;
  esac
fi

exit 0
