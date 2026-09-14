<#
github-repo-check.ps1 —— 打包规范校验。存在任何 BLOCKER 时退出码 3。

检查项:
  1. .gitignore 是否存在，且是否覆盖该技术栈的必备忽略项（node_modules / 构建产物 / 环境变量 / 凭据）
  2. 是否有文件超过 GitHub 硬限制（默认 100MB → BLOCKER；50MB → WARN）
  3. 是否误提交 node_modules / dist / build / target / .venv 等应忽略目录
  4. 是否包含可执行文件与二进制（.exe/.dll/.so/.jar/.zip…）
  5. 是否包含 .git-secrets.local / github.env 这类本 skill 的凭据文件
  6. LICENSE 是否存在（缺失 → WARN，不阻塞）。会识别 MIT / Apache-2.0 / GPL / BSD 等
  7. .gitattributes 是否存在、text=auto 是否设置（跨平台换行规范）
  8. 项目类型识别（Node / Python / Go / Rust / Java / .NET / PHP / Ruby / C-C++ / 通用）

用法:
  pwsh -File github-repo-check.ps1 -ProjectPath <项目根>
  pwsh -File github-repo-check.ps1 -ProjectPath <项目根> -Json
  pwsh -File github-repo-check.ps1 -ProjectPath <项目根> -StagedOnly     # 只看已跟踪/暂存文件
  pwsh -File github-repo-check.ps1 -ProjectPath <项目根> -ReportPath <路径>
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ProjectPath,
  [string]$ReportPath,
  [switch]$Json,
  [switch]$StagedOnly,
  [int]$WarnFileMB = 50,
  [int]$BlockFileMB = 100
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ProjectPath)) { Write-Error "项目路径不存在: $ProjectPath"; exit 1 }
$root = (Resolve-Path -LiteralPath $ProjectPath).Path.TrimEnd('\', '/')
$isGitRepo = Test-Path -LiteralPath (Join-Path $root '.git')

# 外部命令助手。注意：受限执行环境拒绝「dot-source 进来的函数里启动子进程」，
# 所以下面所有 git 调用都先登记成 $gitOps，再由本脚本**顶层**统一执行一次。
. (Join-Path $PSScriptRoot 'github-git.ps1')

function New-GitOp {
  param([string]$Key, [string[]]$Arguments)
  # 项目目录不可写时（例如扫描本 skill 自己的安装目录）跳过 git 检查，不报错。
  try {
    return [pscustomobject]@{ Key = $Key; Cap = (New-Capture -Exe 'git' -Arguments $Arguments -WorkDir $root) }
  } catch {
    return [pscustomobject]@{ Key = $Key; Cap = $null; Error = $_.Exception.Message }
  }
}

$gitOps = @()
if ($isGitRepo) {
  $gitOps += New-GitOp 'ls-files' @('ls-files')
  $gitOps += New-GitOp 'head' @('rev-parse', '--verify', 'HEAD')
  $gitOps += New-GitOp 'cat-file' @('cat-file', '--batch-check=%(objecttype) %(objectname) %(objectsize) %(rest)', '--batch-all-objects')
  $gitOps += New-GitOp 'user-name' @('config', '--get', 'user.name')
  $gitOps += New-GitOp 'user-email' @('config', '--get', 'user.email')
}

$blockers = New-Object System.Collections.Generic.List[string]
$warns    = New-Object System.Collections.Generic.List[string]
$infos    = New-Object System.Collections.Generic.List[string]
$fixes    = New-Object System.Collections.Generic.List[string]

function Add-Blocker { param([string]$m) $script:blockers.Add($m) }
function Add-Warn    { param([string]$m) $script:warns.Add($m) }
function Add-Info    { param([string]$m) $script:infos.Add($m) }

# ── 0. 项目类型识别 ─────────────────────────────────────────────────────────
$types = New-Object System.Collections.Generic.List[string]
$ex = { param($n) Test-Path -LiteralPath (Join-Path $root $n) }
if (& $ex 'package.json')   { $types.Add('Node') }
if ((& $ex 'pyproject.toml') -or (& $ex 'requirements.txt') -or (& $ex 'setup.py') -or (& $ex 'Pipfile') -or (& $ex 'poetry.lock')) { $types.Add('Python') }
if (& $ex 'go.mod')         { $types.Add('Go') }
if (& $ex 'Cargo.toml')     { $types.Add('Rust') }
if ((& $ex 'pom.xml') -or (& $ex 'build.gradle') -or (& $ex 'build.gradle.kts') -or (& $ex 'settings.gradle')) { $types.Add('Java') }
if (Get-ChildItem -LiteralPath $root -Filter '*.csproj' -File -ErrorAction SilentlyContinue) { $types.Add('.NET') }
if ((& $ex 'composer.json')) { $types.Add('PHP') }
if ((& $ex 'Gemfile'))       { $types.Add('Ruby') }
if ((& $ex 'CMakeLists.txt') -or (& $ex 'Makefile')) { $types.Add('C/C++') }
if (& $ex 'Dockerfile')     { $types.Add('Docker') }
if ($types.Count -eq 0) { $types.Add('通用') }
$typeLine = ($types -join ' + ')

# ── 1. .gitignore ───────────────────────────────────────────────────────────
$gitignorePath = Join-Path $root '.gitignore'
$ignoreLines = @()
if (Test-Path -LiteralPath $gitignorePath) {
  $ignoreLines = @(Get-Content -LiteralPath $gitignorePath -Encoding UTF8 | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' })
  Add-Info ".gitignore 存在（$($ignoreLines.Count) 条有效规则）"
} else {
  Add-Warn '.gitignore 不存在，建议生成后再提交'
}

$requiredIgnore = New-Object System.Collections.Generic.List[object]
$requiredIgnore.Add([pscustomobject]@{ Need = 'node_modules'; Re = '(?i)(^|/)node_modules'; Why = '依赖目录，绝不应提交'; For = @('Node'); Add = @('node_modules/', '.pnpm-store/') })
$requiredIgnore.Add([pscustomobject]@{ Need = 'dist/build 产物'; Re = '(?i)(^|/)(dist|build|out|\.next|\.nuxt|target|bin|obj)(/|$)'; Why = '构建产物，可由源码重建'; For = @('Node', 'Java', '.NET', 'Rust', 'C/C++', 'Go'); Add = @('dist/', 'build/', 'out/', '*.tsbuildinfo') })
$requiredIgnore.Add([pscustomobject]@{ Need = '.env 环境变量'; Re = '(?i)^\.?env'; Why = '环境变量文件常含真实密钥'; For = @('*'); Add = @('.env', '.env.*', '!.env.example') })
$requiredIgnore.Add([pscustomobject]@{ Need = '凭据文件'; Re = '(?i)(secrets?|credentials?|\.git-secrets|github\.env|\.npmrc|\.pem|\.key|\.p12)'; Why = '凭据/密钥材料'; For = @('*'); Add = @('.git-secrets.local', 'github.env', '*.pem', '*.key', '*.p12', 'secrets/') })
$requiredIgnore.Add([pscustomobject]@{ Need = '日志文件'; Re = '(?i)(\.log$|logs?/)'; Why = '日志可能夹带密钥与用户数据'; For = @('*'); Add = @('*.log', 'logs/') })
$requiredIgnore.Add([pscustomobject]@{ Need = '编辑器/系统垃圾'; Re = '(?i)(\.DS_Store|Thumbs\.db|desktop\.ini|\.idea|\.vscode)'; Why = '本机环境噪声'; For = @('*'); Add = @('.DS_Store', 'Thumbs.db', '.idea/', '.vscode/') })
$requiredIgnore.Add([pscustomobject]@{ Need = 'Python 缓存'; Re = '(?i)(__pycache__|\.pyc|\.venv|venv/)'; Why = 'Python 运行时产物'; For = @('Python'); Add = @('__pycache__/', '*.py[cod]', '.venv/', 'venv/') })
$requiredIgnore.Add([pscustomobject]@{ Need = '.NET 产物'; Re = '(?i)^\[?Bb\]?in/?|^\[?Oo\]?bj/?'; Why = '.NET 编译产物'; For = @('.NET'); Add = @('bin/', 'obj/') })

foreach ($req in $requiredIgnore) {
  $applies = ($req.For -contains '*') -or ($types | Where-Object { $req.For -contains $_ })
  if (-not $applies) { continue }
  $found = $false
  foreach ($l in $ignoreLines) { if ($l -match $req.Re) { $found = $true; break } }
  if (-not $found) {
    Add-Warn ".gitignore 缺少规则：$($req.Need)（$($req.Why)）"
    foreach ($a in $req.Add) { $fixes.Add($a) }
  }
}

# ── 2/3/4/5. 文件遍历 ───────────────────────────────────────────────────────
# 先把登记过的 git 操作在**顶层**跑掉（cmd.exe 只能从调用方脚本顶层启动），
# 后面的分支都要读这些结果。
$git = @{}
if ($isGitRepo) {
  $runnable = @($gitOps | Where-Object { $_.Cap })
  if ($runnable.Count -lt $gitOps.Count) {
    Add-Warn '项目目录不可写，已跳过部分 git 检查（工作目录需要可写才能生成临时包装脚本）'
  }
  foreach ($op in $runnable) { cmd.exe /c $op.Cap.CommandLine }
  foreach ($op in $runnable) { $git[$op.Key] = Get-Capture -Capture $op.Cap }
}

$skipDirNames = @('.git', 'node_modules', 'dist', 'build', 'out', 'target', 'vendor',
                  '.venv', 'venv', '__pycache__', '.next', 'coverage', '.cache', '.idea',
                  'bin', 'obj', 'Pods', '.gradle', '.terraform', 'tmp', 'temp', '.dsh-release')

$candidateFiles = New-Object System.Collections.Generic.List[object]
if ($StagedOnly -and $isGitRepo) {
  $lr = $git['ls-files']
  if (-not $lr -or -not $lr.Ok) { Write-Error "git ls-files 失败: $(if ($lr) { $lr.StdErr } else { '未执行' })"; exit 1 }
  foreach ($f in $lr.Lines) {
    if ([string]::IsNullOrWhiteSpace($f)) { continue }
    $full = Join-Path $root ($f -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (Test-Path -LiteralPath $full -PathType Leaf) { $candidateFiles.Add([pscustomobject]@{ Full = $full; Rel = $f }) }
  }
} else {
  $stack = New-Object System.Collections.Stack
  $stack.Push($root)
  while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    try { $entries = Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop } catch { continue }
    foreach ($e in $entries) {
      if ($e -is [System.IO.DirectoryInfo]) {
        if ($skipDirNames -contains $e.Name) { continue }
        if ($e.LinkType) { continue }
        $stack.Push($e.FullName)
        continue
      }
      $rel = $e.FullName.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'
      $candidateFiles.Add([pscustomobject]@{ Full = $e.FullName; Rel = $rel })
    }
  }
}

$shouldIgnoreDirs = @('node_modules', '.venv', 'venv', 'dist', 'build', 'out', 'target', '__pycache__', '.next', 'coverage')
$execExts = @('.exe', '.dll', '.so', '.dylib', '.msi', '.bat', '.cmd', '.com', '.scr', '.jar', '.war', '.class', '.apk', '.ipa', '.app', '.deb', '.rpm')
$archiveExts = @('.zip', '.7z', '.rar', '.tar', '.gz', '.tgz', '.bz2', '.xz', '.iso', '.dmg', '.pkg', '.whl')

$largeFiles = New-Object System.Collections.Generic.List[object]
$execFiles = New-Object System.Collections.Generic.List[string]
$archiveFiles = New-Object System.Collections.Generic.List[string]
$junkDirs = New-Object System.Collections.Generic.HashSet[string]
$credFiles = New-Object System.Collections.Generic.List[string]
$blockExts = @('.exe', '.dll', '.so', '.dylib', '.msi', '.iso', '.dmg', '.jar', '.war', '.class', '.apk', '.ipa', '.deb', '.rpm', '.p12', '.pfx', '.jks', '.keystore', '.sqlite', '.db')

$trackedForCheck = $candidateFiles
if (-not $StagedOnly -and $isGitRepo) {
  $trackedList = if ($git['ls-files'] -and $git['ls-files'].Ok) { @($git['ls-files'].Lines) } else { @() }
  if ($trackedList.Count -gt 0) {
    $trackedSet = New-Object System.Collections.Generic.HashSet[string]
    foreach ($t in $trackedList) { [void]$trackedSet.Add(($t -replace '\\', '/')) }
    $trackedForCheck = New-Object System.Collections.Generic.List[object]
    foreach ($c in $candidateFiles) { if ($trackedSet.Contains($c.Rel)) { $trackedForCheck.Add($c) } }
  } else {
    $trackedForCheck = New-Object System.Collections.Generic.List[object]   # 尚未提交任何文件
  }
}

foreach ($f in $trackedForCheck) {
  $name = [System.IO.Path]::GetFileName($f.Full)
  $ext = [System.IO.Path]::GetExtension($f.Full).ToLowerInvariant()
  $segments = $f.Rel.Split('/')
  if ($segments.Length -gt 1) {
    for ($i = 0; $i -lt $segments.Length - 1; $i++) {
      if ($shouldIgnoreDirs -contains $segments[$i]) { [void]$junkDirs.Add($segments[$i]) }
    }
  }
  if ($name -in @('.git-secrets.local', 'github.env', '.npmrc', '.netrc')) { $credFiles.Add($f.Rel) }
  $size = 0
  try { $size = (Get-Item -LiteralPath $f.Full -Force).Length } catch { continue }
  $mb = [math]::Round($size / 1MB, 2)
  if ($size -ge ($BlockFileMB * 1MB)) { $largeFiles.Add([pscustomobject]@{ Rel = $f.Rel; MB = $mb; Level = 'BLOCKER' }) }
  elseif ($size -ge ($WarnFileMB * 1MB)) { $largeFiles.Add([pscustomobject]@{ Rel = $f.Rel; MB = $mb; Level = 'WARN' }) }
  if ($execExts -contains $ext) { $execFiles.Add("$($f.Rel) ($mb MB)") }
  if ($archiveExts -contains $ext) { $archiveFiles.Add("$($f.Rel) ($mb MB)") }
}

foreach ($j in $junkDirs) { Add-Blocker "已跟踪的文件里包含应忽略目录：$j/ —— 请 git rm -r --cached $j" }
foreach ($c in $credFiles) { Add-Blocker "已跟踪凭据文件：$c —— 立即从索引移除并轮换该凭据" }
foreach ($l in $largeFiles) {
  if ($l.Level -eq 'BLOCKER') { Add-Blocker "文件超过 GitHub 100MB 硬限制：$($l.Rel) ($($l.MB) MB)" }
  else { Add-Warn "大文件 $($l.Rel) ($($l.MB) MB)，建议改用 Git LFS 或移出仓库" }
}
if ($execFiles.Count -gt 0) {
  Add-Warn ("已跟踪可执行文件 $($execFiles.Count) 个：" + (($execFiles | Select-Object -First 5) -join '; ') + $(if ($execFiles.Count -gt 5) { ' …' } else { '' }))
}
if ($archiveFiles.Count -gt 0) {
  Add-Warn ("已跟踪压缩包/镜像 $($archiveFiles.Count) 个：" + (($archiveFiles | Select-Object -First 5) -join '; '))
}

# ── 6. 历史里的超大对象 ─────────────────────────────────────────────────────
if ($isGitRepo) {
  $headR = $git['head']
  if ($headR -and $headR.Ok) {
    $histBig = @()
    $sizes = $git['cat-file']
    if ($sizes -and $sizes.Ok) {
      foreach ($line in $sizes.Lines) {
        if ($line -match '^blob \S+ (\d+) (.+)$') {
          $bytes = [int64]$Matches[1]
          if ($bytes -ge ($WarnFileMB * 1MB)) { $histBig += ('{0} ({1} MB)' -f $Matches[2], [math]::Round($bytes / 1MB, 2)) }
        }
      }
      if ($histBig.Count -gt 0) {
        Add-Warn ("历史对象里存在大文件 $($histBig.Count) 个（即使现在删除，仍会占仓库体积）：" + (($histBig | Select-Object -First 5) -join '; '))
      }
    } else {
      Add-Info '历史大对象检查跳过（git cat-file 失败）'
    }
  } else {
    Add-Info '仓库尚无提交（首次提交）'
  }
}

# ── 7. LICENSE ──────────────────────────────────────────────────────────────
$licenseFile = @('LICENSE', 'LICENSE.md', 'LICENSE.txt', 'COPYING', 'LICENSE-MIT') | Where-Object { Test-Path -LiteralPath (Join-Path $root $_) } | Select-Object -First 1
$licenseKind = 'unknown'
if ($licenseFile) {
  $head = Get-Content -LiteralPath (Join-Path $root $licenseFile) -TotalCount 200 -Encoding UTF8 -ErrorAction SilentlyContinue
  $joined = ($head -join "`n")
  if ($joined -match 'MIT License') { $licenseKind = 'MIT' }
  elseif ($joined -match 'Apache License') { $licenseKind = 'Apache-2.0' }
  elseif ($joined -match 'GNU GENERAL PUBLIC LICENSE') {
    if ($joined -match 'Version 3') { $licenseKind = 'GPL-3.0' } elseif ($joined -match 'Version 2') { $licenseKind = 'GPL-2.0' } else { $licenseKind = 'GPL' }
  }
  elseif ($joined -match 'GNU LESSER GENERAL PUBLIC LICENSE') { $licenseKind = 'LGPL' }
  elseif ($joined -match 'BSD') { $licenseKind = 'BSD' }
  elseif ($joined -match 'Mozilla Public License') { $licenseKind = 'MPL-2.0' }
  elseif ($joined -match 'The Unlicense') { $licenseKind = 'Unlicense' }
  Add-Info "LICENSE 存在（识别为 $licenseKind）"
} else {
  Add-Warn 'LICENSE 缺失。开源仓库建议补一个；私有仓库可忽略'
}

# ── 8. .gitattributes ───────────────────────────────────────────────────────
$gaPath = Join-Path $root '.gitattributes'
if (Test-Path -LiteralPath $gaPath) {
  $ga = Get-Content -LiteralPath $gaPath -Encoding UTF8 -ErrorAction SilentlyContinue
  if (($ga -join "`n") -match '(?im)^\s*\*?\s*text\s*=\s*auto|eol\s*=') { Add-Info '.gitattributes 存在且设置了换行规范' }
  else { Add-Warn '.gitattributes 存在但未设置 text=auto 或 eol=，跨平台换行可能被反复改写' }
} else {
  Add-Warn '.gitattributes 不存在，建议加入 text=auto 与二进制声明'
}

# ── 9. git 身份 ─────────────────────────────────────────────────────────────
$gn = if ($git['user-name'] -and $git['user-name'].Ok) { $git['user-name'].StdOut } else { '' }
$ge = if ($git['user-email'] -and $git['user-email'].Ok) { $git['user-email'].StdOut } else { '' }
if (-not $gn -or -not $ge) {
  Add-Warn "git 提交身份不完整（user.name='$gn' user.email='$ge'）。需由 skill 配置后才能提交"
}

# ── 汇总 ────────────────────────────────────────────────────────────────────
$verdict = if ($blockers.Count -gt 0) { 'BLOCK（禁止推送）' } elseif ($warns.Count -gt 0) { 'PASS-WITH-WARNINGS（可推送，建议先处理告警）' } else { 'PASS（规范）' }

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('=== 打包规范校验报告 ===')
$lines.Add("项目      : $root")
$lines.Add("项目类型  : $typeLine")
$lines.Add("模式      : " + $(if ($StagedOnly) { '仅已跟踪文件' } else { '全部文件' }))
$lines.Add("结论      : $verdict")
$lines.Add('')
if ($blockers.Count -gt 0) { $lines.Add('【BLOCKER】'); foreach ($b in $blockers) { $lines.Add("  [X] $b") }; $lines.Add('') }
if ($warns.Count -gt 0)    { $lines.Add('【WARN】');    foreach ($w in $warns)    { $lines.Add("  [!] $w") }; $lines.Add('') }
if ($infos.Count -gt 0)    { $lines.Add('【INFO】');    foreach ($i in $infos)    { $lines.Add("  [i] $i") }; $lines.Add('') }
if ($fixes.Count -gt 0) {
  $lines.Add('建议补进 .gitignore 的内容（skill 可在得到你同意后自动写入）：')
  foreach ($fx in $fixes) { $lines.Add("  $fx") }
  $lines.Add('')
  $lines.Add('建议补进 .gitattributes 的内容：')
  foreach ($ln in @('* text=auto', '*.png binary', '*.jpg binary', '*.pdf binary', '*.zip binary', '*.exe binary')) { $lines.Add("  $ln") }
  $lines.Add('')
}
$text = ($lines -join [Environment]::NewLine)

if ($ReportPath) {
  $dir = Split-Path -Parent $ReportPath
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  Set-Content -LiteralPath $ReportPath -Value $text -Encoding UTF8
}

if ($Json) {
  [ordered]@{
    root = $root
    projectTypes = @($types)
    verdict = $verdict
    blockerCount = $blockers.Count
    warnCount = $warns.Count
    blockers = @($blockers)
    warns = @($warns)
    infos = @($infos)
    license = $licenseKind
    licenseFile = $licenseFile
    gitignorePresent = (Test-Path -LiteralPath $gitignorePath)
    gitattributesPresent = (Test-Path -LiteralPath $gaPath)
    isGitRepo = $isGitRepo
  } | ConvertTo-Json -Depth 5
} else {
  Write-Output $text
}

if ($blockers.Count -gt 0) { exit 3 } else { exit 0 }
