# 发布自检清单

按顺序走，任何一步的「否」都要停下来问用户，不要自行跳过。

## A. 前置

- [ ] 项目根目录已确认（不是「当前目录大概是」）
- [ ] `Get-GitHubCredentials` 返回 `Ok = $true`（令牌存在）
- [ ] `git config --global user.name` 与 `user.email` 非空
- [ ] 已问清：新建仓库 还是 复用已有仓库
- [ ] 已问清：仓库可见性（默认 private）
- [ ] 已问清：项目名称、项目类型、一句话定位
- [ ] 网络可达（`git ls-remote` 对公开仓库能通；不通则先修代理，别急着输令牌）

## B. 规范校验

- [ ] `github-repo-check.ps1` 无 BLOCKER
- [ ] `.gitignore` 覆盖依赖目录、构建产物、`.env`、凭据文件、日志
- [ ] 没有 `node_modules` / `dist` / `build` / `.venv` 被跟踪
- [ ] 没有大于 100MB 的文件
- [ ] 可执行文件与压缩包已确认（或已移出）
- [ ] LICENSE 已决定（有 / 补上 / 明确不要）
- [ ] `.gitattributes` 存在且 `* text=auto`
- [ ] 历史大对象告警已向用户说明

## C. 敏感信息

- [ ] `github-secret-scan.ps1` 无 BLOCKER
- [ ] WARN 项已逐条向用户确认
- [ ] 凭据文件（`.git-secrets.local` / `github.env`）已在 `.gitignore` 且未被跟踪
- [ ] 确认 remote URL **不含**用户名密码
- [ ] 确认令牌**不在**任何将提交的文件里

## D. 文案（推送前给用户看过）

- [ ] README.md 已生成，命令与项目实际一致
- [ ] README.en.md 已生成（或用户明确不要）
- [ ] 版本号与 tag 已确认，理由已说明
- [ ] commit message 已确认

## E. 提交与推送

- [ ] `git add` 后跑过 `-StagedOnly` 双复查
- [ ] `git status --short` 清单已给用户确认
- [ ] commit 已执行（一个语义完整的提交，不要一股脑 `update` 这种信息）
- [ ] push 成功
- [ ] tag 已创建并单独 push（`git push origin <tag>`）
- [ ] 若仓库默认分支非 main，已相应调整

## F. 收尾

- [ ] 仓库链接、tag、commit 短哈希已交付
- [ ] 项目介绍文案已交付
- [ ] 下次发版的版本号提示已给出
- [ ] 已知隐患（大文件、WARN 项、未轮换的旧密钥）已明确告知
