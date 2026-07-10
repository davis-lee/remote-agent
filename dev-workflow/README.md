# dev-workflow —— Claude Code 规范开发流程

给容器内的 Claude Code 装上一套开发纪律:**先理解需求 → 分析 / 定位根因 → 等你审核 → 拉分支开发 → 自检 → 交付待审,由你确认后再推送 / 合并**。

## 组成

| 文件 | 作用 | 机制 |
|---|---|---|
| `CLAUDE.md` | 全局工作流约定,让 Claude 一开始就按规矩来 | 软约定(指令) |
| `commands/spec.md` | `/spec` 需求分析出方案,不写代码 | 斜杠命令 |
| `commands/bugfix.md` | `/bugfix` 先定位根因再修 | 斜杠命令 |
| `commands/ship.md` | `/ship` 展示 diff + 自检后停下待审 | 斜杠命令 |
| `hooks/git-guard.sh` | 拦截 push/merge/reset --hard/主分支直接提交 | Claude PreToolUse 钩子(早拦 + 反馈) |
| `git-hooks/pre-push` | push 的 race-proof 硬后盾 | git 原生钩子(可选,按仓库启用) |

两层防护:`CLAUDE.md` 让它自觉守规矩;`git-guard.sh` 在它想越界时早拦;`pre-push` 是 git 内部的硬后盾,不受 bypass 模式竞态影响。

## 安装(在容器内)

```bash
# 服务器上,把 dev-workflow 拷进容器并运行安装脚本
docker compose cp dev-workflow ai-agents:/tmp/dev-workflow
docker compose exec ai-agents bash /tmp/dev-workflow/install.sh
```

配置写入 `~/.claude`(持久化 volume,重建容器不丢)。之后:

- 全局 `CLAUDE.md`、`/spec` `/bugfix` `/ship`、git-guard 钩子**立即对所有项目生效**。
- push 硬后盾**自动**:install.sh 配好 git 模板(`init.templateDir`),之后每个新 `clone` / `init` 的仓库自动带 `pre-push`,不用逐个手动。
  - 已存在的仓库补钩子:进目录跑一次 `git init`(对已有仓库安全,只补钩子,不动代码与历史),或 `wf-protect`。
- 推送由你执行:审核后 `approve-push`(等价 `HUMAN_PUSH=1 git push`)。

## 日常怎么走

```text
你:/spec 给用户列表加分页
Claude:复述理解 + 列疑问 + 出方案,停下
你:确认 / 修正方案 → "可以,开始"
Claude:拉 feat/pagination 分支,开发,自检
Claude:/ship → 展示 diff + 测试结果,停下
你:审核 → approve-push(或自己 push / 开 PR)
```

修 bug 用 `/bugfix`,其余相同。

## 安全边界(重要,如实说明)

- 这套 hook 防得住 Claude**自主或误操作**推送 / 合并 / 毁坏分支——它不会在你没点头时把东西推上去。
- 防**不住**"你亲口让 Claude 绕过":客户端钩子最终运行在你控制的会话里,你让它 `HUMAN_PUSH=1 git push` 它就能推。要一道**连你授意 Claude 也越不过**的关卡,只有 GitHub 服务器端**分支保护**(main 只能 PR 合并)——那是另一层,按需再加。
- `git-guard.sh` 在 `--dangerously-skip-permissions` 下**设计上照常拦截**;但社区报告个别版本 bypass 模式存在竞态。真正的 push 硬保证来自 `wf-protect` 装的 git 原生 `pre-push`,建议在重要仓库都跑一次。

## 调整

- 改流程:编辑 `~/.claude/CLAUDE.md`。
- 改拦截范围:编辑 `~/.claude/hooks/git-guard.sh` 的匹配规则。
- 加命令:在 `~/.claude/commands/` 放新的 `.md`,即成 `/命令名`。
