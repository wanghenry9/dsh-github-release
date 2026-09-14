<#
github-repo-create.ps1 —— 用 PAT 调用 GitHub REST API：验证令牌 / 查询仓库 / 创建仓库。

不使用 gh CLI（本机未安装）。令牌从 github-credentials.ps1 取，不落盘、不写进 git config。

用法:
  # 验证令牌有效性（不会打印令牌）
  pwsh -File github-repo-create.ps1 -Probe

  # 查询仓库是否存在，存在 → exit 0，不存在 → exit 4
  pwsh -File github-repo-create.ps1 -Status -Owner <用户或组织> -Name <仓库名>

  # 新建仓库（已存在则直接返回成功，不报错）
  pwsh -File github-repo-create.ps1 -Create -Name <仓库名> -Visibility private -Description "简介"
  pwsh -File github-repo-create.ps1 -Create -Name <仓库名> -Owner <组织名> -Visibility public

  # 要把「已有本地项目」推上去，必须加 -NoAutoInit：
  # 不加时 GitHub 默认 auto_init=true，会先生成一个 README 提交，远程就有了本地
  # 没有的历史，push 直接被拒（! [rejected] ... fetch first，实测踩过）。
  pwsh -File github-repo-create.ps1 -Create -Name <仓库名> -NoAutoInit -Visibility private

退出码: 0 成功 / 2 凭据缺失 / 3 API 失败或权限不足 / 4 仓库不存在
#>
[CmdletBinding(DefaultParameterSetName = 'Probe')]
param(
  [Parameter(ParameterSetName = 'Probe')][switch]$Probe,
  [Parameter(ParameterSetName = 'Status', Mandatory = $true)][switch]$Status,
  [Parameter(ParameterSetName = 'Create', Mandatory = $true)][switch]$Create,
  [string]$Owner = '',
  [string]$Name = '',
  [ValidateSet('private', 'public')][string]$Visibility = 'private',
  [string]$Description = '',
  [string]$Homepage = '',
  [switch]$NoAutoInit,
  [switch]$Json,
  [string]$RepoPath = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
$apiBase = 'https://api.github.com'

# 同进程读取凭据（受限执行环境不允许子进程使用管道，不能靠 pwsh -File 抓输出）
. (Join-Path $PSScriptRoot 'github-credentials.ps1')

function Get-Token {
  $creds = Get-GitHubCredentials -RepoPath $RepoPath
  if (-not $creds.Ok) { return $null }
  return $creds.Token
}

function Invoke-GitHubApi {
  param(
    [string]$Method,
    [string]$Path,
    [string]$Token,
    [hashtable]$Body
  )
  $headers = @{
    'Authorization'        = "Bearer $Token"
    'Accept'               = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'dsh-github-release-skill'
  }
  $params = @{ Method = $Method; Uri = "$apiBase$Path"; Headers = $headers; ErrorAction = 'Stop' }
  if ($PSBoundParameters.ContainsKey('Body') -and $Body) {
    $params['Body'] = ($Body | ConvertTo-Json -Depth 5)
    $params['ContentType'] = 'application/json; charset=utf-8'
  }
  try {
    $resp = Invoke-RestMethod @params
    return @{ Ok = $true; Data = $resp; Status = 200 }
  } catch {
    $status = 0
    $msg = $_.Exception.Message
    $respStream = $null
    if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
      try { $status = [int]$_.Exception.Response.StatusCode } catch { }
      try {
        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $respStream = $reader.ReadToEnd()
      } catch { }
    }
    $apiMsg = ''
    if ($respStream) {
      try { $apiMsg = ($respStream | ConvertFrom-Json).message } catch { $apiMsg = $respStream }
    }
    return @{ Ok = $false; Status = $status; Message = $msg; ApiMessage = $apiMsg; Raw = $respStream }
  }
}

function Write-Fail {
  param([string]$Reason, [string]$Hint, [int]$Code)
  if ($Json) {
    [ordered]@{ ok = $false; error = $Reason; hint = $Hint; exitCode = $Code } | ConvertTo-Json -Depth 4
  } else {
    Write-Output "FAIL: $Reason"
    if ($Hint) { Write-Output "提示: $Hint" }
  }
  exit $Code
}

$token = Get-Token
if (-not $token) {
  Write-Fail -Reason '未找到可用的 GITHUB_TOKEN' -Hint "请把令牌填进 $env:USERPROFILE\.dsh\secrets\github.env（模板见 skill 的 assets\github-env.template）" -Code 2
}

# ── Probe ───────────────────────────────────────────────────────────────────
if ($Probe) {
  $r = Invoke-GitHubApi -Method GET -Path '/user' -Token $token
  if (-not $r.Ok) {
    if ($r.Status -eq 401) { Write-Fail -Reason '令牌无效或已过期（HTTP 401）' -Hint '重新生成 PAT：https://github.com/settings/personal-access-tokens/new' -Code 3 }
    Write-Fail -Reason "调用 /user 失败（HTTP $($r.Status)）：$($r.ApiMessage)$($r.Message)" -Hint '检查网络与代理设置' -Code 3
  }
  $login = $r.Data.login
  $kind = if ($r.Data.type) { $r.Data.type } else { 'User' }
  if ($Json) {
    [ordered]@{ ok = $true; login = $login; type = $kind; name = $r.Data.name; tokenValid = $true } | ConvertTo-Json -Depth 4
  } else {
    Write-Output "TOKEN OK  身份: $login ($kind)"
    if ($r.Data.name) { Write-Output "显示名: $($r.Data.name)" }
  }
  exit 0
}

if (-not $Name) { Write-Fail -Reason '缺少 -Name（仓库名）' -Hint '用法：-Create -Name myrepo -Visibility private' -Code 1 }

# 未指定 Owner 时用令牌所属账号
if (-not $Owner) {
  $me = Invoke-GitHubApi -Method GET -Path '/user' -Token $token
  if (-not $me.Ok) { Write-Fail -Reason "无法确定账号（HTTP $($me.Status)）" -Hint '请显式传 -Owner' -Code 3 }
  $Owner = $me.Data.login
}

# ── Status ──────────────────────────────────────────────────────────────────
if ($Status) {
  $r = Invoke-GitHubApi -Method GET -Path "/repos/$Owner/$Name" -Token $token
  if ($r.Ok) {
    $d = $r.Data
    if ($Json) {
      [ordered]@{ ok = $true; exists = $true; fullName = $d.full_name; visibility = $d.visibility; defaultBranch = $d.default_branch; cloneUrl = $d.clone_url; sshUrl = $d.ssh_url; empty = ($d.size -eq 0) } | ConvertTo-Json -Depth 4
    } else {
      Write-Output "REPO EXISTS  $($d.full_name)  可见性=$($d.visibility)  默认分支=$($d.default_branch)  大小=$($d.size)KB"
      Write-Output "CLONE_URL=$($d.clone_url)"
    }
    exit 0
  }
  if ($r.Status -eq 404) { exit 4 }
  Write-Fail -Reason "查询仓库失败（HTTP $($r.Status)）：$($r.ApiMessage)" -Hint '确认令牌对该仓库有访问权限' -Code 3
}

# ── Create ──────────────────────────────────────────────────────────────────
$body = @{
  name        = $Name
  private     = ($Visibility -eq 'private')
  description = $Description
  auto_init   = (-not $NoAutoInit)
}
if ($Homepage) { $body['homepage'] = $Homepage }

# 个人账号用 /user/repos；组织用 /orgs/{org}/repos。先试个人端点，404 时换组织端点。
$attempts = @('/user/repos', "/orgs/$Owner/repos")
$last = $null
$created = $null
foreach ($p in $attempts) {
  $r = Invoke-GitHubApi -Method POST -Path $p -Token $token -Body $body
  if ($r.Ok) { $created = $r.Data; break }
  $last = $r
  # 422 = 已存在或参数问题；404 = 该端点不适用（换成组织端点再试）
  if ($r.Status -eq 422) {
    if ($r.ApiMessage -match 'already exists') {
      $exist = Invoke-GitHubApi -Method GET -Path "/repos/$Owner/$Name" -Token $token
      if ($exist.Ok) { $created = $exist.Data; break }
    }
    Write-Fail -Reason "创建仓库被拒绝（HTTP 422）：$($r.ApiMessage)" -Hint '检查仓库名是否合法、是否与已有仓库冲突' -Code 3
  }
  if ($r.Status -eq 401) { Write-Fail -Reason '令牌无效（HTTP 401）' -Hint '重新生成 PAT' -Code 3 }
  if ($r.Status -eq 403) { Write-Fail -Reason "权限不足（HTTP 403）：$($r.ApiMessage)" -Hint '细粒度令牌需要 Administration: Read and write 才能在组织下建仓' -Code 3 }
  continue
}

if (-not $created) {
  $hint = if ($last -and $last.Status -eq 404) { '细粒度令牌需要把目标账号/组织加入 Repository access，并授予 Administration: Read and write' } else { '确认网络、令牌权限' }
  Write-Fail -Reason "创建仓库失败（HTTP $($last.Status)）：$($last.ApiMessage)$($last.Message)" -Hint $hint -Code 3
}

if ($Json) {
  [ordered]@{ ok = $true; created = $true; fullName = $created.full_name; visibility = $created.visibility; defaultBranch = $created.default_branch; cloneUrl = $created.clone_url; htmlUrl = $created.html_url } | ConvertTo-Json -Depth 4
} else {
  Write-Output "REPO READY  $($created.full_name)  可见性=$($created.visibility)  默认分支=$($created.default_branch)"
  Write-Output "CLONE_URL=$($created.clone_url)"
  Write-Output "HTML_URL=$($created.html_url)"
}
exit 0
