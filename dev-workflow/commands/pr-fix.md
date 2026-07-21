---
description: 接取当前分支 PR 的评审意见,逐条修改,提交并推送更新 PR
argument-hint: [可选:PR 号 / 补充说明]
---
根据 GitHub 上的评审意见修改当前分支的 PR($ARGUMENTS):

1. **拉取意见**:定位当前分支对应的 PR(或参数指定的 PR 号),用 gh 取回评审意见:
   - `gh pr view --comments`(总体评论 / review 概述)
   - `gh api repos/{owner}/{repo}/pulls/{n}/comments`(行级 review 评论,含文件与行号)
   把待处理意见逐条列出。
2. **逐条处理**:每条说明你的理解与改法;遇到有异议或含糊的先提出、不猜着改。
3. **实施 + 自检**:改完跑 `gofmt` / 构建 / 测试;有失败先修。
4. **提交更新**:`git commit`(信息里引用对应意见)+ `git push` 更新同一分支,PR 自动刷新。
5. **回评(可选)**:用 `gh pr comment` 简述"已按 X 意见修改"。
6. **汇报**:改了哪些、对应哪条意见、自检结果、PR 链接。

全程在功能分支上;不要合并、不要推送到 `main`。
