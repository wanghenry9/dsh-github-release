---
name: github-release
description: 把本地项目按规范打包并推送到 GitHub 仓库，全程含敏感信息阻断扫描、规范校验、语义化版本打 tag、自动生成中英文 README 与项目介绍文案，并支持用 PAT 新建仓库。当用户说「推送到 GitHub」「打包上传仓库」「自动提交 GitHub」「发个版本」「建仓库并上传」「生成项目介绍」时使用本 Skill。
---

# 打包并推送项目到 GitHub

一套**有闸门**的发布流程。每个闸门都可能阻断推送——这是刻意的：宁可停下问一句，也不要把密钥或垃圾文件推上公网。

## 0. 铁律（任何时候不得违反）

1. **绝不读取、回显、打印、记录令牌明文。** 只看 `github-credentials.ps1 -Check` 的掩码输出。
2. **绝不把令牌写进任何会进 git 的文件**：不写 remote URL（`https://user:token@github.com/...` 是禁止的写法）、不写 `.git/config`、不写 README、不写日志。令牌只通过进程环境变量喂给 `git credential`。
3. **绝不把凭据文件加进暂存区。** `.git-secrets.local` / `github.env` / `~/.dsh/secrets/github.env` 永不 `git add`。
4. **扫描出 BLOCKER 就停手。** 不猜、不替用户决定「这个应该没事」，把 `文件:行号` 列出来让用户处理。
5. **未经用户在那一步明确确认，不执行 `git commit` 和 `git push`。** 一次确认只授权一次动作，不连锁授权。
6. **不猜版本号、不猜仓库名、不猜项目类型。** 都要问。
7. **不把疑似密钥的内容贴进对话。** 只给路径、行号、规则名和掩码片段。
8. 如果命中的文件用户要求「先看看」，提醒他：直接读会把密钥写进对话记录，建议先自己改掉或轮换。

## 1. 标准工作流

> **执行环境前提（必读，两条都是实测结论）**
>
> **① 远程 git 操作（`push` / `pull` / `fetch` / `ls-remote`）需要放开沙箱。**
> 沙箱禁止子进程建立管道，而 git 必须给传输助手（`git-remote-https` / `git-remote-ssh`）
> 建双向管道，因此在默认的 `workspace-write` 下会直接失败：
> ```
> error: cannot create standard input pipe for remote-https: Permission denied
> ```
> 这与网络无关——同一个 `git ls-remote` 在放开沙箱后立即成功。
> **打包、扫描、规范校验、README、commit 全部可以在沙箱内完成；只有真正 push 的
> 那几条命令需要申请一次 `danger-full-access`。** 申请前先跟用户说清楚要做什么。
> 另外：沙箱的出口代理会拦截 DNS 落在保留段（`198.18.0.0/15`，Clash fake-IP 常见）
> 的 TLS 连接，报 `安全包中没有可用的凭证`——那也是沙箱侧的现象，放开后自愈。
> **不需要为 GitHub 配 `http.proxy`**：git 自己走系统 TUN 就通。
>
> **② 外部命令只能在「调用方脚本的顶层语句」里启动。**
> 把调用包进任何函数（尤其是 dot-source 进来的函数）都会被拒，报
> `StandardOutputEncoding is only supported when standard output is redirected`
> 或 `拒绝访问` / `0xC0000142`。因此本 skill 的脚本一律采用
> 「**声明式登记 → 顶层一次性执行 → 再消费结果**」：
> ```powershell
> . "$skill\scripts\github-git.ps1"
> $cap = New-Capture -Exe 'git' -Arguments @('status','--short') -WorkDir $ProjectPath
> cmd.exe /c $cap.CommandLine          # ← 必须是当前脚本的顶层语句
> $r = Get-Capture -Capture $cap        # → @{ Ok; ExitCode; StdOut; Lines }
> ```

### 步骤 1 · 定位项目 + 凭据自检

先确定项目根目录。不要假设当前目录就是项目——先列目录、找 `.git` / `package.json` / `pyproject.toml` 等标志文件，把候选列给用户确认。

然后**同进程**读取凭据状态（不要用 `pwsh -File` 去抓输出，受限环境会失败）：

```powershell
$skill = Join-Path $env:DSH_HOME 'skills\github-release'
. (Join-Path $skill 'scripts\github-credentials.ps1')
$creds = Get-GitHubCredentials -RepoPath $ProjectPath
$creds.Ok; $creds.TokenMasked; $creds.Username; $creds.Email
```

若 `Ok = $false`：**停**。告诉用户把 PAT 填进 `$env:DSH_HOME\secrets\github.env`（模板在 skill 的 `assets\github-env.template`），填完再继续。同时确认 git 身份：

```powershell
git config --global user.name    # 空则需配置，否则无法 commit
git config --global user.email   # 建议用 GitHub 的 noreply 隐私邮箱
```

用户没说清楚就用 `ask_user_question` 问一次，拿到后写入**全局**配置（不要写进项目 config，避免把个人信息提交进仓库）。

### 步骤 2 · 问「新建仓库还是复用已有」

必须问，不要默认。两个分支都要准备好。

**复用已有**：确认仓库地址，然后探测可达性与是否为空：

```powershell
git ls-remote https://github.com/<owner>/<repo>.git   # 空仓库也能成功，只是没有任何 ref
```

- 非空且已有历史 → 需要 `git pull --rebase` 或先 `git fetch`，**不要**直接 force push。
- 私有仓库匿名访问会 401/403，这是正常的：此时给 remote 配上凭据助手后重试。

**新建仓库**（PAT 需要 Administration: Read and write）：

```powershell
pwsh -NoProfile -File "$skill\scripts\github-repo-create.ps1" -Probe                      # 先验令牌
pwsh -NoProfile -File "$skill\scripts\github-repo-create.ps1" -Status -Name <repo>        # 已存在？exit 0/4
pwsh -NoProfile -File "$skill\scripts\github-repo-create.ps1" -Create -Name <repo> -Visibility private -Description "<一句话简介>"
```

> **要把已有本地项目推上去，必须加 `-NoAutoInit`。**
> 不带它是 GitHub 默认行为（`auto_init=true`），GitHub 会先生成一个 README 提交，
> 于是远程有了本地没有的历史，push 会被拒：
> ```
> ! [rejected]  main -> main (fetch first)
> ```
> 想让 GitHub 自动初始化，就得先 `git pull --rebase` 再推——不如直接建空仓库干净。

**可见性必须问用户**，默认 private（默认值偏安全一侧）。脚本会打印 `CLONE_URL=`，用它配 remote。

### 步骤 3 · 问「项目名称 + 项目类型」

用 `ask_user_question` 问，一次问齐：

- **项目名称**（中文/英文都行，用来写文案与 README 标题）
- **项目类型**：CLI 工具 / 库或 SDK / Web 应用 / 桌面应用 / 后端服务 / 数据分析或脚本 / 插件扩展 / 学习练习或 Demo / 其他（让他自己描述）
- **一句话定位**：给谁用、解决什么问题

再自己读代码补齐事实依据（不要编）：入口文件、依赖清单、构建与运行命令、目录结构、有没有测试。**README 里出现的每条命令都必须是项目里真实存在的**——写之前先去 `package.json` 的 `scripts`、`pyproject.toml`、`Makefile` 里核对。

### 步骤 4 · 规范校验 + 敏感扫描（两道闸门）

```powershell
pwsh -NoProfile -File "$skill\scripts\github-repo-check.ps1" -ProjectPath $ProjectPath -ReportPath "$ProjectPath\.dsh-release\repo-check.txt"
pwsh -NoProfile -File "$skill\scripts\github-secret-scan.ps1" -ProjectPath $ProjectPath -ReportPath "$ProjectPath\.dsh-release\secret-scan.txt"
```

- `github-repo-check.ps1`：`.gitignore` 覆盖度、大文件（>100MB 硬阻断）、`node_modules`/`dist` 等误提交、可执行文件与压缩包、历史大对象、LICENSE、`.gitattributes`、git 身份。**exit 3 = 有 BLOCKER。**
- `github-secret-scan.ps1`：GitHub/OpenAI/AWS/Google/Slack/Stripe/npm/PyPI/HuggingFace 令牌、私钥 PEM、带口令连接串、Bearer 令牌、密码赋值、内网 IP。**exit 3 = 命中 BLOCKER。**

拿到报告后：

1. 有 BLOCKER → 把 `文件:行号` 列表给用户，问他怎么处理（改掉 / 轮换密钥 / 确认是误报 / 加进忽略名单）。**不要自己往下走。**
2. 有 WARN → 说明风险，问是否继续。
3. 用户说「某条是误报」→ 用 `-Ignore '<模式>'` 排除该路径重扫，或者在用户明确同意下把该文件加进 `.gitignore`。**绝不修改扫描规则本身来放行。**

`-StagedOnly` 是推前最后一道复查（只看已跟踪文件），在 `git add` 之后、`git commit` 之前跑一遍。

### 步骤 5 · 算版本号并确认 tag

规则（必须让用户确认或改写，不要静默打 tag）：

| 情况 | 版本 |
| --- | --- |
| 首次发布 | `v0.1.0` |
| 修 bug / 小改动 / 文档 | PATCH +1 |
| 加功能 / 兼容性变更 | MINOR +1 |
| 破坏性变更 / 用户说「重构了大版本」 | MAJOR +1 |

先看已有 tag：

```powershell
git tag --sort=-v:refname | Select-Object -First 5
```

不存在就 `v0.1.0`，存在就按上面的规则递增，把「当前 → 建议」和理由摆给用户。

### 步骤 6 · 生成 README + 项目介绍

**先把要写的文案列给用户看，得到确认再落盘。** 不要在未确认时新建/覆盖 README。

产出物：

- `README.md` —— 中文为主，含：一句话介绍、特性列表、环境要求、安装、快速开始、配置项、目录结构、常见问题、License。只写代码里真实存在的命令。
- `README.en.md` —— 英文版，内容对齐（项目类型是学习练习/Demo 或用户不想要英文时可省，但要问一句）。
- LICENSE —— 缺失时问用户选哪个（MIT / Apache-2.0 / 不授权私有），不要替他选。
- `.gitignore` 补充 —— 按 `github-repo-check.ps1` 的报告补，**必须包含凭据文件规则**：`.git-secrets.local`、`github.env`、`*.pem`、`*.key`、`.env`、`secrets/`，以及**本 skill 自己产生的运行目录 `.dsh-release/`**。
- `.gitattributes` —— `* text=auto` 加二进制声明。

> `.dsh-release/` 是 `New-Capture` 写临时 `.bat` 与日志的地方，**必须进 `.gitignore`**，
> 否则会把运行残留一起提交。每次发布结束后可以整个删掉。

**推送后**再生成一份「项目介绍文案」交付给用户：一句话电梯陈述、面向使用者的功能段落、面向开发者的技术要点、标签关键词、适合放 GitHub About 的简短描述。这是给人看的文案，不是文件。

### 步骤 7 · 提交与推送（每步单独确认）

**配置 remote**（先确保没有把令牌写进 URL）：

```powershell
git -C $ProjectPath remote remove origin  # 若已存在错误 remote
git -C $ProjectPath remote add origin https://github.com/<owner>/<repo>.git
```

**配凭据助手**（令牌只在进程环境里，不落盘）。把下面这段整理成一次调用：

```powershell
. "$skill\scripts\github-git.ps1"
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$env:GITHUB_TOKEN = $creds.Token
$cap = New-Capture -Exe 'git' -Arguments @('-C', $ProjectPath, 'config', 'credential.helper',
  '!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "$GITHUB_TOKEN"; }; f') -WorkDir $ProjectPath
cmd.exe /c $cap.CommandLine          # ← 顶层语句
$r = Get-Capture -Capture $cap
$ErrorActionPreference = $prevEap
Remove-Item Env:\GITHUB_TOKEN
if (-not $r.Ok) { throw "配置凭据助手失败: $($r.StdOut)" }
```

要点：令牌通过 `$env:GITHUB_TOKEN` 传给 git 的 shell 形式 credential helper，**不写进 remote URL、不写进 .git/config、不落盘**。配置完立刻 `Remove-Item Env:\GITHUB_TOKEN`。

**提交**（先 `git add`，再复查，再 commit）：

```powershell
$capAdd = New-Capture -Exe 'git' -Arguments @('-C', $ProjectPath, 'add', '-A') -WorkDir $ProjectPath
cmd.exe /c $capAdd.CommandLine
$rAdd = Get-Capture -Capture $capAdd
if (-not $rAdd.Ok) { throw "git add 失败: $($rAdd.StdOut)" }

$capSt = New-Capture -Exe 'git' -Arguments @('-C', $ProjectPath, 'status', '--short') -WorkDir $ProjectPath
cmd.exe /c $capSt.CommandLine
$st = Get-Capture -Capture $capSt

pwsh -NoProfile -File "$skill\scripts\github-repo-check.ps1" -ProjectPath $ProjectPath -StagedOnly
pwsh -NoProfile -File "$skill\scripts\github-secret-scan.ps1" -ProjectPath $ProjectPath -StagedOnly
```

两条都 exit 0 之后，把 `$st.Lines` 的**完整文件清单**给用户看，得到确认再提交：

```powershell
$capC = New-Capture -Exe 'git' -Arguments @('-C', $ProjectPath, 'commit', '-m', '<type>(<scope>): <中文简述>', '-m', '<正文：改了什么、为什么>') -WorkDir $ProjectPath
cmd.exe /c $capC.CommandLine
$rc = Get-Capture -Capture $capC
if (-not $rc.Ok) { throw "commit 失败: $($rc.StdOut)" }
```

**推送**（同样逐条顶层执行；**这几条需要一次 `danger-full-access` 授权**，理由与做法见本节开头的「执行环境前提 ①」）：

```powershell
# 推分支
$capP = New-Capture -Exe 'git' -Arguments @('-C', $ProjectPath, 'push', '-u', 'origin', $branch) -WorkDir $ProjectPath
cmd.exe /c $capP.CommandLine
$rp = Get-Capture -Capture $capP -TimeoutMs 300000
# 打 tag 并推 tag
$capT = New-Capture -Exe 'git' -Arguments @('-C', $ProjectPath, 'tag', '-a', $tag, '-m', "<tag 说明>") -WorkDir $ProjectPath
cmd.exe /c $capT.CommandLine
$rt = Get-Capture -Capture $capT
$capT2 = New-Capture -Exe 'git' -Arguments @('-C', $ProjectPath, 'push', 'origin', $tag) -WorkDir $ProjectPath
cmd.exe /c $capT2.CommandLine
$rt2 = Get-Capture -Capture $capT2 -TimeoutMs 300000
```

推送输出里若出现 `403` / `Authentication failed` → 令牌权限不足或过期。若出现 `could not read Username` → 凭据助手没生效或 `GITHUB_TOKEN` 没传进进程。若出现超时/SSL → 网络/代理问题，见下面的「网络」一节。

**判断 push 是否真的成功**：只看 git 的退出码。`! [rejected]` 这类冲突也会让退出码非零，要读 `StdOut` 区分「认证失败」与「需要先 pull」。

### 步骤 8 · 汇报

给用户一份结构化交付（用 `dsh-ui` 渲染，不要写成大段文字）：

- 仓库链接、tag、commit 短哈希、分支
- 规范校验与敏感扫描的最终结论
- 本次写入/修改的文件清单
- 项目介绍文案
- 后续维护提示：下次发版要递增到哪个版本、tag 怎么打

## 2. 网络与代理

**先分清是「沙箱挡的」还是「你本机网络真的不通」——两者的处理完全不同。**

| 现象 | 判断 | 处理 |
| --- | --- | --- |
| `cannot create standard input pipe for remote-https / ssh: Permission denied` | 沙箱挡的（管道） | 放开沙箱重试，不要去折腾代理 |
| TLS 报 `安全包中没有可用的凭证`，且 DNS 落在 `198.18.0.0/15` | 沙箱出口代理拒绝保留段 IP | 放开沙箱重试；`web_fetch` 也会报 "resolves to a non-public IP" |
| 放开沙箱后仍超时 / SSL 失败 | 本机网络或代理链路问题 | 才需要排查代理 |

排查本机代理的顺序：

1. `git ls-remote https://github.com/<owner>/<repo>.git` 报超时/SSL 失败 → 网络问题，不是令牌问题。
2. 查代理端口是否在监听：`Test-NetConnection 127.0.0.1 -Port 7897`（Clash Verge 默认 7897，可从 `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\config.yaml` 的 `mixed-port` 确认）。
3. 端口通但握手失败 → 代理内核到上游节点的链路不通，**必须让用户自己去代理软件里换节点**，不要反复重试。
4. **不要急着给 git 配代理**。Clash 开了 TUN 模式时，git 走系统路由就通，硬塞 `http.proxy` 反而可能把本来能用的连接弄坏（实测这台机器就是这样）。
5. 确实需要显式代理时，只给 GitHub 配，不动系统代理：
   ```powershell
   git config --global http.https://github.com.proxy http://127.0.0.1:7897
   ```
   **动用户的 git 全局配置前必须先探测代理可用、并征得同意。** 探测失败就停下报告，不要写入一个不通的代理把用户其它 git 操作也弄坏。

## 3. 故障排查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `cannot create standard input pipe for remote-https / ssh` | 沙箱禁止 git 给传输助手建管道 | 放开沙箱（`danger-full-access`）；本地 git 操作不受影响 |
| TLS `安全包中没有可用的凭证` + DNS 在 `198.18.0.0/15` | 沙箱出口代理拒绝保留段 IP | 放开沙箱；不是令牌或证书问题 |
| `! [rejected] main -> main (fetch first)` | 仓库被 `auto_init` 初始化过，远程已有提交 | 建仓时加 `-NoAutoInit`，或先 `git pull --rebase` |
| `StandardOutputEncoding is only supported when standard output is redirected` | 在函数里启动子进程，或被捕获 | 改成调用方**顶层**的 `New-Capture` + `cmd.exe /c` + `Get-Capture` 三步式 |
| `Program 'x.exe' failed to run: 拒绝访问` | 同上（`[Process]::Start`、`Start-Process -Redirect*`、`pwsh` 子进程都被拒） | 同上；包装进程只能用 `cmd.exe` |
| 退出码永远是 0 | 用了 `cmd /c "cmd /c '...' & echo %ERRORLEVEL%"`：`%ERRORLEVEL%` 在解析期就展开了 | 改用 `New-Capture` 生成的 `.bat` 包装，退出码由 `.bat` 运行时求值 |
| `The filename, directory name, or volume label syntax is incorrect` | `.bat` 用了 ASCII 编码，中文路径变成 `????` | 写 `.bat` 必须 UTF-8 无 BOM |
| 子进程写日志失败 / `0xC0000142` | 往系统 temp 写 | 日志写到项目内 `.dsh-release\.run`（记得进 `.gitignore`） |
| `Could not find a part of the path ...\.dsh-release\.run\...` | 目标目录不可写（例如扫描 skill 自己的安装目录） | `New-CapturePlan` 纯构造 + 顶层自行处理写入失败；扫描脚本已内置降级 |
| 扫描结果里出现 `references/secret-scan-rules.md` 命中 | 那是**规则文档里的示例文本**，不是泄漏 | 属预期；技能脚本目录已自动排除 |
| 写入 `~/.dsh/...` 被拒绝 | 文件沙箱只允许写工作区 | 装 skill 或建凭据文件时申请一次 `danger-full-access`，并说明理由 |
| `credential.helper` 配好仍要账号密码 | `GITHUB_TOKEN` 没在同一进程里 | 在同一个 PowerShell 会话里设置环境变量后再 push |
| 令牌 write 权限不足 | 细粒度 PAT 缺 Contents: Read and write | 让用户去 token 设置页补权限 |
| 想建仓库但 403 | 缺 Administration: Read and write，或组织未授权 | 同上，或让用户手工建好仓库后走「复用已有」分支 |

### 凭据助手实测结论（cherry-picked）

下面这段配置已实测可用（`Server auth using Basic with user '<用户名>'` →
`HTTP/1.1 200 OK`，git 自行把 Authorization 头 redacted）：

```powershell
git -C <项目> config credential.helper '!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "$GITHUB_TOKEN"; }; f'
```

要点：

- 用户名写 `x-access-token` 即可，GitHub 不校验它，**令牌放在 password 位**。
- 令牌只从 `$env:GITHUB_TOKEN` 读，进程结束即消失，不落盘、不进 `.git/config`。
- 配完记得 `Remove-Item Env:\GITHUB_TOKEN`。
- 推送前设 `$env:GIT_TERMINAL_PROMPT = '0'`：凭据缺失时立即失败，而不是卡在交互提示上。

## 4. 附带资源

- `scripts/github-credentials.ps1` —— 凭据读取与掩码探针（同进程函数 `Get-GitHubCredentials`）
- `scripts/github-git.ps1` —— 外部命令捕获助手 `New-Capture` / `Get-Capture`（`New-CapturePlan` 为纯构造，目标目录不可写时用它）
- `scripts/github-repo-check.ps1` —— 打包规范校验
- `scripts/github-secret-scan.ps1` —— 敏感信息扫描（阻断式；自动排除技能自身脚本目录）
- `scripts/github-repo-create.ps1` —— 令牌探测 / 仓库查询 / 仓库创建
- `assets/github-env.template` —— 凭据文件模板
- `references/secret-scan-rules.md` —— 扫描规则与例外处理
- `references/release-checklist.md` —— 发布自检清单
