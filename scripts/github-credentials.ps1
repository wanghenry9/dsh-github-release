<#
github-credentials.ps1 —— 读取 GitHub 凭据，永不回显明文令牌。

用法:
  pwsh -File github-credentials.ps1 -Check
      → 探针模式：只打印「OK / MISSING」，绝不打印令牌内容。适合放进工作流。

  pwsh -File github-credentials.ps1 -NoMask
      → 机器模式：额外输出 GITHUB_TOKEN=<明文> 一行。
        仅当调用方自己会安全消费这一行时才使用（例如在某个进程内把令牌
        喂给 git 的 credential helper）。任何情况下都不要把它的输出打印到
        对话、日志或文件里。

  pwsh -File github-credentials.ps1
      → 默认：打印掩码后的令牌（如 ghp_ab…wxyz）与其它字段，供人工确认。

查找顺序（先找到先用）:
  1. 环境变量 GITHUB_TOKEN
  2. <项目根>\.git-secrets.local
  3. <项目根>\github.env
  4. $env:DSH_HOME\secrets\github.env   （默认 C:\Users\<你>\.dsh\secrets\github.env）

安全约束:
  · 本脚本只读凭据，不写、不复制、不缓存。
  · 明文令牌只会出现在 stdout 的 GITHUB_TOKEN= 行（且仅在 -NoMask 下）。
  · 若某文件被 git 跟踪，会打印 WARN —— 说明凭据有被提交的风险。
#>
# 本文件有两种用法：
#   1) 直接运行：pwsh -File github-credentials.ps1 [-Check] [-NoMask] [-RepoPath x]
#   2) 被其它脚本 dot-source：. github-credentials.ps1  然后调 Get-GitHubCredentials
# dot-source 时不会执行下面的 CLI 分支，因此不会覆盖调用者的变量。

$ErrorActionPreference = 'Stop'
$script:GhCredDir = Split-Path -Parent $PSCommandPath

function Get-DshHome {
  if ($env:DSH_HOME) { return $env:DSH_HOME }
  return (Join-Path $env:USERPROFILE '.dsh')
}

function Read-CredFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $map = @{}
  foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
    if ($line -match '^\s*#') { continue }
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
      $k = $Matches[1]
      $v = $Matches[2].Trim()
      if ($v.Length -ge 2) {
        if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) {
          $v = $v.Substring(1, $v.Length - 2)
        }
      }
      $map[$k] = $v
    }
  }
  return [pscustomobject]@{ Map = $map; Path = $Path }
}

function Get-GitHubCredentials {
  <#
  .SYNOPSIS
    在「当前进程内」读取 GitHub 凭据（不启子进程，不依赖管道）。
  .DESCRIPTION
    同进程调用是刻意的：受限执行环境不允许子进程使用管道，`$out = & pwsh -File ...`
    会失败。其他脚本应 dot-source 本文件后直接调用本函数。
    返回 [pscustomobject]: Ok / Token / TokenMasked / Username / Email / RepoUrl / Visibility / Source / Warn / Error
  #>
  param([string]$RepoPath = (Get-Location).Path)

  $files = @(
    (Join-Path $RepoPath '.git-secrets.local'),
    (Join-Path $RepoPath 'github.env'),
    (Join-Path (Get-DshHome) 'secrets\github.env')
  )

  $token = $null; $user = $null; $mail = $null; $repoUrl = $null; $vis = $null; $usedFile = $null
  foreach ($f in $files) {
    $parsed = Read-CredFile -Path $f
    if ($null -eq $parsed) { continue }
    $m = $parsed.Map
    if (-not $token   -and $m.ContainsKey('GITHUB_TOKEN')   -and $m['GITHUB_TOKEN'])   { $token = $m['GITHUB_TOKEN']; $usedFile = $f }
    if (-not $user    -and $m.ContainsKey('GITHUB_USERNAME') -and $m['GITHUB_USERNAME']) { $user = $m['GITHUB_USERNAME'] }
    if (-not $mail    -and $m.ContainsKey('GITHUB_EMAIL')   -and $m['GITHUB_EMAIL'])   { $mail = $m['GITHUB_EMAIL'] }
    if (-not $repoUrl -and $m.ContainsKey('GITHUB_REPO_URL') -and $m['GITHUB_REPO_URL']) { $repoUrl = $m['GITHUB_REPO_URL'] }
    if (-not $vis     -and $m.ContainsKey('GITHUB_DEFAULT_VISIBILITY') -and $m['GITHUB_DEFAULT_VISIBILITY']) { $vis = $m['GITHUB_DEFAULT_VISIBILITY'] }
  }

  if (-not $token -and $env:GITHUB_TOKEN) { $token = $env:GITHUB_TOKEN; $usedFile = 'env:GITHUB_TOKEN' }
  if (-not $user -and $env:GITHUB_USERNAME) { $user = $env:GITHUB_USERNAME }
  if (-not $mail -and $env:GITHUB_EMAIL) { $mail = $env:GITHUB_EMAIL }

  $masked = ''
  $ok = $false
  $warns = @()
  if ($token) {
    $token = $token.Trim()
    $ok = $true
    if ($token.Length -le 10) { $masked = ('*' * $token.Length) }
    else { $masked = $token.Substring(0, 4) + ('*' * 6) + $token.Substring($token.Length - 4) }
  }

  # 风险检测只做静态判断（不启动 git）：真正用 git 复查在主流程顶层完成，
  # 因为受限环境不允许从函数里启动子进程。
  $warns = @()
  $credNames = @('.git-secrets.local', 'github.env')
  foreach ($f in $credNames) {
    if (Test-Path -LiteralPath (Join-Path $RepoPath $f)) {
      $warns += "检测到项目内凭据文件 $f —— 确认它已写进 .gitignore 且未被 git 跟踪"
    }
  }

  return [pscustomobject]@{
    Ok          = $ok
    Token       = $token
    TokenMasked = $masked
    Username    = $user
    Email       = $mail
    RepoUrl     = $repoUrl
    Visibility  = $vis
    Source      = $usedFile
    Warn        = $warns
    Error       = if ($ok) { '' } else { "未找到 GITHUB_TOKEN。请把令牌填进 $(Join-Path (Get-DshHome) 'secrets\github.env')（模板见 skill 的 assets\github-env.template）" }
  }
}

function Test-CredFileTracked {
  <#
  .SYNOPSIS
    准备用 git 复查凭据文件是否已被跟踪。
  .DESCRIPTION
    返回 @{ Capture; Present }。Capture 非空时必须由调用方在**顶层**执行：
        cmd.exe /c $probe.Capture.CommandLine
    然后用 Read-TrackedCredFiles 读取（该函数只读文件，不启动进程）。
  #>
  param([string]$RepoPath = (Get-Location).Path)
  $capture = $null
  $present = @()
  foreach ($f in @('.git-secrets.local', 'github.env')) {
    if (Test-Path -LiteralPath (Join-Path $RepoPath $f)) { $present += $f }
  }
  if ($present.Count -gt 0 -and (Test-Path -LiteralPath (Join-Path $RepoPath '.git'))) {
    $capture = New-Capture -Exe 'git' -Arguments @('ls-files') -WorkDir $RepoPath
  }
  return [pscustomobject]@{ Capture = $capture; Present = $present; RepoPath = $RepoPath }
}

function Read-TrackedCredFiles {
  <#
  .SYNOPSIS
    读取已执行的捕获，返回被 git 跟踪的凭据文件警告。只读文件，不启动进程。
  #>
  param($Probe, [int]$TimeoutMs = 30000)
  $warns = @()
  if ($null -eq $Probe -or $null -eq $Probe.Capture) { return $warns }
  $r = Get-Capture -Capture $Probe.Capture -TimeoutMs $TimeoutMs
  if (-not $r.Ok) { return $warns }
  $tracked = @($r.Lines | Where-Object { $_ -ne '' } | ForEach-Object { ($_ -replace '\\', '/').Trim() })
  foreach ($f in $Probe.Present) {
    if ($tracked -contains $f) {
      $warns += "凭据文件 $f 已被 git 跟踪，凭据有被提交的风险！请执行 git rm --cached $f 并轮换该凭据"
    }
  }
  return $warns
}

function Show-GitHubCredentials {
  <#
  .SYNOPSIS
    组装凭据报告对象（不打印、不启动子进程），返回 @{ Result; TrackProbe }。
  #>
  param(
    [string]$RepoPath = (Get-Location).Path
  )

  $creds = Get-GitHubCredentials -RepoPath $RepoPath
  $result = [ordered]@{
    OK                 = $creds.Ok
    TOKEN_MASKED       = $creds.TokenMasked
    TOKEN              = $creds.Token
    USERNAME           = $creds.Username
    EMAIL              = $creds.Email
    REPO_URL           = $creds.RepoUrl
    DEFAULT_VISIBILITY = $creds.Visibility
    SOURCE             = $creds.Source
    WARN               = @($creds.Warn)
    ERROR              = $creds.Error
  }
  $trackProbe = Test-CredFileTracked -RepoPath $RepoPath
  return [pscustomobject]@{ Result = $result; TrackProbe = $trackProbe }
}

function Write-GitHubCredentials {
  <#
  .SYNOPSIS
    打印凭据报告并返回进程退出码（不调用 exit，方便被顶层复用）。
  .DESCRIPTION
    全部报告都用 Write-Host 输出：调用方通常写成 $code = Write-GitHubCredentials ...，
    若用 Write-Output，函数输出会被吸进 $code 变量而不显示给用户。
  #>
  param(
    [Parameter(Mandatory = $true)]$Report,
    [switch]$Check,
    [switch]$NoMask
  )
  $result = $Report.Result
  $say = { param($m) Write-Host $m }

  if ($Check) {
    if ($result.OK) {
      & $say "CREDENTIALS OK  token=$($result.TOKEN_MASKED)  source=$($result.SOURCE)"
      if ($result.USERNAME) { & $say "GITHUB_USERNAME=$($result.USERNAME)" }
      if ($result.EMAIL) { & $say "GITHUB_EMAIL=$($result.EMAIL)" }
      if ($result.REPO_URL) { & $say "GITHUB_REPO_URL=$($result.REPO_URL)" }
    } else {
      & $say 'CREDENTIALS MISSING'
      & $say $result.ERROR
    }
    foreach ($w in $result.WARN) { & $say "WARN $w" }
    if ($result.OK) { return 0 } else { return 2 }
  }

  if ($NoMask) {
    if (-not $result.OK) { [Console]::Error.WriteLine($result.ERROR); return 2 }
    & $say "GITHUB_TOKEN=$($result.TOKEN)"
    & $say "GITHUB_USERNAME=$($result.USERNAME)"
    & $say "GITHUB_EMAIL=$($result.EMAIL)"
    & $say "GITHUB_REPO_URL=$($result.REPO_URL)"
    & $say "GITHUB_DEFAULT_VISIBILITY=$($result.DEFAULT_VISIBILITY)"
    & $say "SOURCE=$($result.SOURCE)"
    foreach ($w in $result.WARN) { & $say "WARN $w" }
    return 0
  }

  & $say "OK              : $($result.OK)"
  & $say "TOKEN_PRESENT   : $($result.OK)"
  & $say "TOKEN_MASKED    : $($result.TOKEN_MASKED)"
  & $say "GITHUB_USERNAME : $($result.USERNAME)"
  & $say "GITHUB_EMAIL    : $($result.EMAIL)"
  & $say "REPO_URL        : $($result.REPO_URL)"
  & $say "VISIBILITY      : $($result.DEFAULT_VISIBILITY)"
  & $say "SOURCE          : $($result.SOURCE)"
  if ($result.ERROR) { & $say "ERROR           : $($result.ERROR)" }
  foreach ($w in $result.WARN) { & $say "WARN            : $w" }
  return 0
}

# 仅在「直接运行本文件」时执行 CLI；被 dot-source 时只暴露上面的函数。
# 用 $MyInvocation.InvocationName -ne '.' 判断：-File 运行时它是脚本路径，
# dot-source 时是 '.'。不要依赖 $MyInvocation.MyCommand.Path（-File 下不可靠）。
function Read-GhCliArgs {
  $sw = @{ Check = $false; NoMask = $false; RepoPath = (Get-Location).Path }
  for ($i = 0; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    if ($a -eq '-Check') { $sw.Check = $true; continue }
    if ($a -eq '-NoMask') { $sw.NoMask = $true; continue }
    if ($a -eq '-RepoPath' -and ($i + 1) -lt $args.Count) { $sw.RepoPath = [string]$args[$i + 1]; $i++; continue }
    if ($a -like '-RepoPath=*') { $sw.RepoPath = $a.Substring(10); continue }
  }
  return $sw
}

if ($MyInvocation.InvocationName -ne '.') {
  $cli = Read-GhCliArgs @args
  . (Join-Path $script:GhCredDir 'github-git.ps1')
  $report = Show-GitHubCredentials -RepoPath $cli.RepoPath
  if ($report.TrackProbe.Capture) {
    # 顶层执行（函数里不能启动子进程，见 github-git.ps1 头部说明）
    cmd.exe /c $report.TrackProbe.Capture.CommandLine
    $report.Result.WARN += Read-TrackedCredFiles -Probe $report.TrackProbe
  }
  $code = Write-GitHubCredentials -Report $report -Check:$cli.Check -NoMask:$cli.NoMask
  exit $code
}
