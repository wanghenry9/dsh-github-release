# dsh-github-release

> 给 [DeepSeek Harness](https://github.com/)（DSH）用的一套**有闸门**的 GitHub 发布 Skill：
> 一句话让 agent 把本地项目按规范打包、扫描敏感信息、生成中英文 README，
> 再推上 GitHub 并打语义化版本 tag。

技能名（`SKILL.md` frontmatter）是 **`github-release`**；仓库名是 **`dsh-github-release`**。
安装时目录必须叫 `github-release`，否则技能不会被 DSH 加载。

---

## 它做什么

对着任意项目说一句「把这个项目推到 GitHub」，agent 就会加载本技能，然后按下面的闸门流程走。
**每个闸门都可能阻断推送——这是刻意的**：宁可停下问一句，也不要把密钥或垃圾文件推上公网。

| 步骤 | 内容 | 闸门 |
| --- | --- | --- |
| 1 | 定位项目根 + 读凭据（掩码探针，绝不回显令牌） | 凭据缺失即停 |
| 2 | 问清「新建仓库还是复用已有」+ 可见性 | 必须问，不猜 |
| 3 | 问清「项目名称 / 项目类型 / 一句话定位」 | 必须问，不猜 |
| 4 | **敏感信息扫描**（阻断式）+ **打包规范校验** | 有 BLOCKER 即停 |
| 5 | 算语义化版本号并确认 tag（首版 `v0.1.0`） | 必须确认，不静默打 tag |
| 6 | 生成 `README.md` + `README.en.md` + `.gitignore` / `.gitattributes` | 文案先确认 |
| 7 | 逐条确认后 `commit` / `push` / 打 tag | 每步单独授权 |
| 8 | 交付仓库链接、tag、commit 与项目介绍文案 | — |

## 特性

- **阻断式敏感扫描** —— GitHub / OpenAI / AWS / Google / Slack / Stripe / npm / PyPI / HuggingFace
  令牌、私钥 PEM、带口令连接串、Bearer 令牌、密码赋值、内网 IP。命中即 `exit 3`，只输出
  `文件:行号` + 掩码片段，**绝不把密钥贴进对话**。
- **打包规范校验** —— `.gitignore` 覆盖度、>100MB 大文件硬阻断、`node_modules` / `dist` 误提交、
  压缩包与可执行文件、历史大对象、LICENSE / `.gitattributes` 缺失、git 身份是否配好。
- **令牌零落盘** —— 令牌只从 `~/.dsh/secrets/github.env` 读，仅通过**进程环境变量**喂给
  git 的 shell 形式 credential helper；不写 remote URL、不写 `.git/config`、不进日志。
- **不依赖 `gh` CLI** —— 建仓库直接走 GitHub REST API，少一个安装步骤。
- **沙箱感知** —— 脚本按「声明式登记 → 顶层一次性执行 → 再消费结果」编写，在 DSH 的
  `workspace-write` 沙箱下也能完成扫描、校验、生成文档、`add` / `commit` / `tag`。

## 环境要求

| 项 | 要求 |
| --- | --- |
| 操作系统 | **Windows**（脚本用 `cmd.exe` 包装子进程并求值 `%ERRORLEVEL%`） |
| PowerShell | **PowerShell 7+**（`pwsh`） |
| Git | 任意较新版本，需在 `PATH` 中 |
| 第三方模块 | **无**。只用内置 cmdlet + `git` |
| `gh` CLI | **不需要** |
| 凭据 | 一个 GitHub PAT（细粒度或经典均可） |

## 安装

本仓库是技能的**源目录**（可版本管理、可重新安装）。DSH 从用户级技能根加载，所以要把它
复制成 `github-release` 这个名字：

```powershell
git clone https://github.com/wanghenry9/dsh-github-release.git
$src = Join-Path (Get-Location) 'dsh-github-release'
$dst = Join-Path $env:DSH_HOME 'skills\github-release'   # 默认 C:\Users\<你>\.dsh\skills\github-release

New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item (Join-Path $src 'SKILL.md') $dst -Force
Copy-Item (Join-Path $src 'scripts')    $dst -Recurse -Force
Copy-Item (Join-Path $src 'assets')     $dst -Recurse -Force
Copy-Item (Join-Path $src 'references') $dst -Recurse -Force
```

DSH 对技能目录有文件监听，复制完立即生效，**不需要重启**。

> 技能装在 `$DSH_HOME/skills/`（用户级技能根）而不是 DSH 安装目录里，
> 所以 `dsh` 升级不会覆盖它。

## 配置凭据

把 PAT 填进 `$env:DSH_HOME\secrets\github.env`（模板见 `assets/github-env.template`）：

```ini
GITHUB_TOKEN=你的令牌
GITHUB_USERNAME=你的GitHub用户名
GITHUB_EMAIL=你的GitHub邮箱或noreply隐私邮箱
```

令牌建议用 **Fine-grained token**（<https://github.com/settings/personal-access-tokens/new>）：

| 权限 | 值 | 用途 |
| --- | --- | --- |
| `Contents` | Read and write | 推送代码 / 建 tag / 建 release |
| `Metadata` | Read-only | 勾 `Contents` 时会自动带上 |
| `Administration` | Read and write | 仅当要让技能帮你**新建仓库** |

经典 token 勾 `repo` 即可。

**查找顺序**（先找到先用）：环境变量 `GITHUB_TOKEN` → `<项目根>\.git-secrets.local`
→ `<项目根>\github.env` → `$env:DSH_HOME\secrets\github.env`。

验证探针（只打印掩码，绝不打印明文）：

```powershell
pwsh -NoProfile -File "$env:DSH_HOME\skills\github-release\scripts\github-credentials.ps1" -Check
```

## 快速开始

装好并填好凭据之后，直接对 agent 说：

```
把这个项目推到 GitHub
```

或者显式点名技能：`用 github-release 帮我打包上传`。

## 目录结构

```
SKILL.md                         技能主文档（工作流、铁律、故障排查表）
README.md                        本文件（中文）
README.en.md                     English
LICENSE                          MIT
scripts/
  github-credentials.ps1         凭据读取与掩码探针（Get-GitHubCredentials）
  github-git.ps1                 受限沙箱下的外部命令捕获助手（New-Capture / Get-Capture）
  github-repo-check.ps1          打包规范校验
  github-secret-scan.ps1         敏感信息扫描（阻断式）
  github-repo-create.ps1         令牌探测 / 仓库查询 / 仓库创建（REST API）
assets/
  github-env.template            凭据文件模板
references/
  secret-scan-rules.md           扫描规则与例外处理（含已知盲区）
  release-checklist.md           发布自检清单
```

## 脚本参考

四个脚本都可独立当命令行工具用。

### `github-credentials.ps1`

```powershell
pwsh -File github-credentials.ps1 -Check          # 只打印 OK / MISSING
pwsh -File github-credentials.ps1                 # 打印掩码令牌与其它字段
pwsh -File github-credentials.ps1 -NoMask         # 输出明文令牌行（仅供安全消费，切勿打印）
```

也可被 dot-source：`. github-credentials.ps1` 然后调用 `Get-GitHubCredentials -RepoPath <路径>`。

### `github-repo-check.ps1` —— 打包规范校验

```powershell
pwsh -File github-repo-check.ps1 -ProjectPath <项目根> -ReportPath <报告路径>
pwsh -File github-repo-check.ps1 -ProjectPath <项目根> -StagedOnly   # 只看已暂存文件
```

开关：`-Json` / `-StagedOnly` / `-WarnFileMB 50` / `-BlockFileMB 100`。
**退出码 `3` = 有 BLOCKER。**

### `github-secret-scan.ps1` —— 敏感信息扫描

```powershell
pwsh -File github-secret-scan.ps1 -ProjectPath <项目根> -ReportPath <报告路径>
pwsh -File github-secret-scan.ps1 -ProjectPath <项目根> -StagedOnly
pwsh -File github-secret-scan.ps1 -ProjectPath <项目根> -Ignore '文档/示例.md','tests\*'
```

开关：`-Json` / `-StagedOnly` / `-NoMask` / `-MaxHits 400` / `-MaxFileMB 4` / `-Ignore <模式,模式>`。
**退出码 `3` = 命中 BLOCKER。**

> `-Ignore` 只用于用户确认过的误报。**绝不修改扫描规则本身来放行。**

### `github-repo-create.ps1` —— 建仓库（REST API）

```powershell
pwsh -File github-repo-create.ps1 -Probe                                  # 验证令牌
pwsh -File github-repo-create.ps1 -Status -Name <仓库名>                   # 存在 → 0，不存在 → 4
pwsh -File github-repo-create.ps1 -Create -Name <仓库名> -Visibility private `
     -Description "一句话简介" -NoAutoInit
```

**要把已有本地项目推上去，必须加 `-NoAutoInit`。** 不加时 GitHub 默认 `auto_init=true`，
会先生成一个 README 提交，于是远程有了本地没有的历史，`push` 直接被拒：

```
! [rejected]  main -> main (fetch first)
```

退出码：`0` 成功 / `2` 凭据缺失 / `3` API 失败或权限不足 / `4` 仓库不存在。

## 安全设计

- **令牌只从凭据文件读**，仅通过进程环境变量喂给 git 的 shell 形式 credential helper：
  ```powershell
  git config credential.helper '!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "$GITHUB_TOKEN"; }; f'
  ```
  用户名写 `x-access-token` 即可（GitHub 不校验它），**令牌放在 password 位**。
  配完立即 `Remove-Item Env:\GITHUB_TOKEN`。
- **凭据文件绝不进入暂存区**：`.git-secrets.local` / `github.env` / `secrets/` 已被
  `.gitignore` 覆盖，`github-repo-check.ps1` 与凭据探针还会检查它是否被 git 跟踪。
- **扫描命中 BLOCKER 就阻断**（`exit 3`），只给路径、行号、规则名和掩码片段。
- 建议把凭据文件 ACL 收紧到仅 `Administrator` / `SYSTEM` / `Administrators` 可读。

## 已知限制：DSH 沙箱

远程 git 操作（`push` / `pull` / `fetch` / `ls-remote`）以及 GitHub REST API 调用
**需要放开沙箱**。沙箱禁止子进程建立管道，而 git 必须给传输助手
（`git-remote-https` / `git-remote-ssh`）建双向管道：

```
error: cannot create standard input pipe for remote-https: Permission denied
```

REST API 调用则是被沙箱出口代理拦下的——DNS 落在保留段 `198.18.0.0/15`
（Clash fake-IP 常见）时报 `安全包中没有可用的凭证`：

```
REST FAIL: The SSL connection could not be established
DNS api.github.com => 198.18.0.112
```

两者都是**沙箱侧现象，与本机网络和令牌无关**，放开沙箱后自愈。

**因此的分工：**

| 环境 | 能做的事 |
| --- | --- |
| 沙箱内（`workspace-write`） | 定位项目、凭据探针、敏感扫描、规范校验、生成 README、`.gitignore` / `.gitattributes`、`git add` / `commit` / `tag` |
| 需要一次完全访问授权 | `git push`、`git push origin <tag>`，以及 GitHub REST API 调用（建仓库 / 复核） |

**不要给 git 配 `http.proxy`。** 开了 TUN 模式时代理本来就走系统路由，
硬塞 `http.proxy` 反而可能把能用的连接弄坏。只有在「放开沙箱后仍然超时 / SSL 失败」时
才需要排查代理，排查顺序见 `SKILL.md` 的「网络与代理」一节。

## 常见问题

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `! [rejected] main -> main (fetch first)` | 建仓库时被 `auto_init` 初始化过，远程已有提交 | 建仓时加 `-NoAutoInit`，或先 `git pull --rebase` |
| `could not read Username` | 凭据助手没生效，或 `GITHUB_TOKEN` 没传进同一进程 | 在同一 PowerShell 会话里设环境变量后再 push |
| `403` / `Authentication failed` | 令牌权限不足或已过期 | 细粒度 PAT 补 `Contents: Read and write` |
| 建仓库返回 `403` | 缺 `Administration: Read and write`，或组织未授权 | 补权限，或手工建好仓库后走「复用已有」分支 |
| `StandardOutputEncoding is only supported when standard output is redirected` | 在函数里启动子进程被沙箱拒 | 改用 `New-Capture` + `cmd.exe /c` + `Get-Capture` 三步式，且必须在**调用方顶层** |
| `The filename, directory name, or volume label syntax is incorrect` | `.bat` 用了 ASCII 编码，中文路径变成 `????` | 写 `.bat` 必须 **UTF-8 无 BOM** |
| 扫描报告里出现 `references/secret-scan-rules.md` 命中 | 那是**规则文档里的示例文本**，不是泄漏 | 属预期；技能脚本目录已自动排除 |

更多故障排查见 `SKILL.md`。

## License

[MIT](LICENSE) © 2026 wanghenry9
