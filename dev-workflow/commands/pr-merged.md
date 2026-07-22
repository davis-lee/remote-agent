---
description: PR 合并后清理:切回 main 拉取最新,删除该 PR 的本地与远程分支
argument-hint: [可选:PR 号 / 分支名]
---
PR 已在 GitHub 合并,执行合并后清理($ARGUMENTS):

1. **确认合并**:定位刚合并的 PR——参数指定的 PR 号/分支,否则用当前分支对应的 PR。用 `gh pr view` 确认 `state=MERGED` 并拿到 `headRefName`(功能分支名)。**若未合并,停下告知、不要删任何分支**。
2. **拉取最新 main**:`git checkout main` → `git pull --ff-only`(拉取合并后的最新代码;失败则报告原因,不要强拉)。
3. **删本地分支**:`git branch -d <功能分支>`(已合并可安全删)。若因未完全合并失败,报告原因、**不要 `-D` 强删**。
4. **删远程分支**:`gh api -X DELETE repos/{owner}/{repo}/git/refs/heads/<功能分支>`(不走 `git push`,避免被 guard 拦;GitHub 若已自动删除,忽略 404)。
5. **汇报**:当前分支、`main` 最新 commit、已删除的本地/远程分支。

约束:不要删除 `main`/`master`;不要 `git push` 到 main;不确定分支名时先确认再删。
