---
description: 交付——功能分支提交、推送、开 PR,然后停下等我在 GitHub 审核
---
开发完成,进入交付(PR 流程):

1. 确认当前在功能分支(`feat/*`、`fix/*`),不在 `main` / `master`。
2. `git status`;运行测试 / lint / 构建,报告结果;有失败先修再继续。
3. `git add` + `git commit`(清晰的提交信息,说明做了什么、为什么)。
4. `git push -u origin <当前分支>`。
5. `gh pr create --base main`,标题简洁;正文含:变更摘要、自检结果、部署前置(如 DB / 表结构变更)、需我重点看的行为变化。
6. 把 PR 链接发我,然后**停下**。不要合并、不要推送到 `main`。

由我在 GitHub 上审核并合并。审完若有意见,用 `/pr-fix` 接取并修改。
