<#
github-secret-scan.ps1 —— 推送前敏感信息扫描。命中任何 BLOCKER 都会让脚本以退出码 3 结束。

设计原则:
  · 只报告 文件:行号 + 规则名 + 掩码后的片段，绝不把疑似密钥原样打印到对话里。
  · 脚本自身所在目录被强制排除，避免把自己文件里的规则字符串当成泄漏。
  · 纯 PowerShell 实现，只依赖 .NET 正则，不依赖 rg / grep。

用法:
  pwsh -File github-secret-scan.ps1 -ProjectPath <项目根>
      文本报告打到 stdout；命中 BLOCKER → exit 3
  pwsh -File github-secret-scan.ps1 -ProjectPath <项目根> -ReportPath <路径>
      同时把报告（不含明文）写入文件，便于归档
  pwsh -File github-secret-scan.ps1 -ProjectPath <项目根> -Json
      输出 JSON，便于程序判断
  pwsh -File github-secret-scan.ps1 -ProjectPath <项目根> -StagedOnly
      只扫描已暂存（git ls-files）的文件——推前最后一道闸
  pwsh -File github-secret-scan.ps1 -ProjectPath <项目根> -NoMask
      调试用：打印未掩码片段。不要在有真实凭据的仓库里用。
  pwsh -File github-secret-scan.ps1 -ProjectPath <项目根> -Ignore '文档/示例.md','tests\*'
      按模式排除已确认的误报。匹配「相对路径」（正/反斜杠两种写法都认）或「文件名」，
      全量与 -StagedOnly 两种模式都生效；被排除的文件数会打印在报告里。
      只用于用户确认过的误报 —— 绝不修改检测规则本身来放行。
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ProjectPath,
  [string]$ReportPath,
  [switch]$Json,
  [switch]$StagedOnly,
  [switch]$NoMask,
  [int]$MaxHits = 400,
  [int]$MaxFileMB = 4,
  [string[]]$Ignore = @()
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ProjectPath)) { Write-Error "项目路径不存在: $ProjectPath"; exit 1 }
$root = (Resolve-Path -LiteralPath $ProjectPath).Path.TrimEnd('\', '/')

# 外部命令助手。受限执行环境拒绝「dot-source 进来的函数里启动子进程」，
# 所以 git ls-files 先登记，再由本脚本顶层执行。
. (Join-Path $PSScriptRoot 'github-git.ps1')

# 技能自身目录强制排除：脚本里写的是正则片段、规则文档里写的是示例文本，都不是泄漏。
# 注意范围要精确：只排除「脚本目录」与「技能顶层文件」，**不要**排除技能根目录的
# 整个子树——否则恰好放在技能目录下的真实项目会被整体漏扫（这比误报严重得多）。
$skillRoot = ''
try { $skillRoot = (Split-Path -Parent $PSScriptRoot).TrimEnd('\', '/') } catch { }
$selfFiles = @()
if ($skillRoot) {
  $selfFiles += (Join-Path $skillRoot 'SKILL.md')
  $selfFiles += (Join-Path $skillRoot 'README.md')
}
$skippedSelf = 0

function Test-SelfPath {
  param([string]$Path)
  if (-not $Path) { return $false }
  $p = $Path.TrimEnd('\', '/')
  # 脚本目录（含其全部子目录）
  if ($PSScriptRoot) {
    $sd = $PSScriptRoot.TrimEnd('\', '/')
    if ($p -eq $sd -or $p.StartsWith($sd + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  # 技能顶层文件（只按完整路径匹配，不递归）
  foreach ($f in $selfFiles) { if ($p -eq $f.TrimEnd('\', '/')) { return $true } }
  return $false
}

$lsCap = $null
if ($StagedOnly) {
  if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) { Write-Error "$root 不是 git 仓库，-StagedOnly 不可用"; exit 1 }
  try { $lsCap = New-Capture -Exe 'git' -Arguments @('ls-files', '--cached', '--others', '--exclude-standard') -WorkDir $root }
  catch { Write-Error "项目目录不可写，无法执行 -StagedOnly（$($_.Exception.Message)）"; exit 1 }
}

# ── 规则表 ──────────────────────────────────────────────────────────────────
# 令牌字面量按片段拼接，避免本文件被自己的规则命中（并且本目录已强制排除）。
$rules = @(
  @{ Id = 'github-token';      Sev = 'BLOCKER'; Desc = 'GitHub 令牌';          Re = ('gh' + '[pousr]_[A-Za-z0-9]{20,}') },
  @{ Id = 'github-pat-fine';   Sev = 'BLOCKER'; Desc = 'GitHub 细粒度令牌';    Re = ('github_' + 'pat_[A-Za-z0-9_]{20,}') },
  @{ Id = 'openai-key';        Sev = 'BLOCKER'; Desc = 'OpenAI 风格密钥';      Re = ('s' + 'k-[A-Za-z0-9_\-]{20,}') },
  @{ Id = 'anthropic-key';     Sev = 'BLOCKER'; Desc = 'Anthropic 密钥';       Re = ('s' + 'k-ant-[A-Za-z0-9_\-]{20,}') },
  @{ Id = 'aws-access-key';    Sev = 'BLOCKER'; Desc = 'AWS Access Key ID';    Re = ('(A3T|AKIA|ASIA|ABIA|ACCA)[0-9A-Z]{16}') },
  @{ Id = 'aws-secret';        Sev = 'BLOCKER'; Desc = 'AWS Secret 赋值';      Re = ('(?i)aws[_\-\. ]?(secret|access)?[_\-\. ]?key[_\-\. ]*["'']?[=:]\s*["'']?[A-Za-z0-9/+=]{30,}') },
  @{ Id = 'google-api-key';    Sev = 'BLOCKER'; Desc = 'Google API Key';       Re = ('AIza[0-9A-Za-z_\-]{30,}') },
  @{ Id = 'slack-token';       Sev = 'BLOCKER'; Desc = 'Slack 令牌';           Re = ('xox[baprse]-[0-9A-Za-z\-]{10,}') },
  @{ Id = 'stripe-key';        Sev = 'BLOCKER'; Desc = 'Stripe 密钥';          Re = ('(sk|rk)_(live|test)_[0-9A-Za-z]{20,}') },
  @{ Id = 'npm-token';         Sev = 'BLOCKER'; Desc = 'npm 令牌';             Re = ('npm_[0-9A-Za-z]{30,}') },
  @{ Id = 'pypi-token';        Sev = 'BLOCKER'; Desc = 'PyPI 令牌';            Re = ('pypi-AgEIcHlwaS5vcmc[A-Za-z0-9_\-]{10,}') },
  @{ Id = 'huggingface-token'; Sev = 'BLOCKER'; Desc = 'HuggingFace 令牌';     Re = ('hf_[0-9A-Za-z]{30,}') },
  @{ Id = 'gitee-token';       Sev = 'BLOCKER'; Desc = 'Gitee 令牌';           Re = ('(?:[0-9a-f]{32})@gitee\.com') },
  @{ Id = 'jwt';               Sev = 'WARN';    Desc = 'JWT 形式的令牌';       Re = ('eyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}') },
  @{ Id = 'private-key';       Sev = 'BLOCKER'; Desc = '私钥 PEM 头';          Re = ('-----BEGIN [A-Z ]*' + 'PRIVATE KEY-----') },
  @{ Id = 'openssh-key';       Sev = 'BLOCKER'; Desc = 'OpenSSH 私钥头';       Re = ('-----BEGIN OPENSSH ' + 'PRIVATE KEY-----') },
  @{ Id = 'conn-string';       Sev = 'BLOCKER'; Desc = '带口令的连接串';       Re = ('(?:mysql|postgres|postgresql|mongodb(?:\+srv)?|redis|amqp|mssql|ftp|ldaps?)://[^\s/:@]+:[^\s/@]{3,}@') },
  @{ Id = 'basic-auth-url';    Sev = 'WARN';    Desc = 'URL 内嵌账号口令';     Re = ('https?://[^\s/:@]+:[^\s/@]{6,}@') },
  @{ Id = 'bearer-token';      Sev = 'BLOCKER'; Desc = 'Bearer 令牌';          Re = ('(?i)bearer\s+[A-Za-z0-9\-_\.=]{25,}') },
  # 赋值型：要求键名像密码/token/secret，且值不是占位符。误报率由此控制。
  @{ Id = 'secret-assign';     Sev = 'BLOCKER'; Desc = '密码/密钥赋值';        Re = ('(?i)(password|passwd|pwd|secret|token|api[_\-]?key|apikey|access[_\-]?key|client[_\-]?secret|private[_\-]?key|auth[_\-]?key|encryption[_\-]?key)\s*[:=]\s*["'']?[A-Za-z0-9+/=_\-\.]{12,}') },
  @{ Id = 'internal-ip';       Sev = 'WARN';    Desc = '内网 IP 地址';         Re = ('\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b') }
)

# 命中值里出现这些占位符就降级为非阻塞提示，避免模板文件刷屏。
# 注意：只对「匹配到的值」判断，绝不对整行判断——否则同行的说明文字会把真实
# 密钥误降级（例如密码 "Hunter2RealPass" 含 "here"、连接串含 "internal"）。
$placeholderRe = "(?i)^(['""]?\s*)?(example|your[_\-]?|sample|placeholder|changeme|change[_\-]?me|dummy|fake|redacted|todo|fixme|notreal|insert[_\-]?your|xxx+|\*\*\*|\.\.\.|<[^>]{0,40}>|\{\{|\$\{|password1|hunter2|abc123|123456)"
$placeholderValueRe = '(?i)^[\s''"]*(your[_\- ]|my[_\- ]|<|\{\{|\$\{|xxx|placeholder|example|changeme|dummy|fake|redacted)'

# ── 文件名层面的规则（无需读内容）──────────────────────────────────────────
# 值为 blocker/ignore/warn；模板文件给予 warn，因为它们很可能确实要提交。
$fileRules = @(
  @{ Glob = '.env';                      Sev = 'BLOCKER'; Desc = '.env 环境变量文件' },
  @{ Glob = '.env.*';                    Sev = 'BLOCKER'; Desc = '.env 环境变量文件'; Except = @('.env.example', '.env.sample', '.env.template') },
  @{ Glob = '*.env';                     Sev = 'BLOCKER'; Desc = '.env 环境变量文件' },
  @{ Glob = '*.pem';                     Sev = 'BLOCKER'; Desc = 'PEM 证书/私钥' },
  @{ Glob = '*.key';                     Sev = 'BLOCKER'; Desc = '密钥文件' },
  @{ Glob = '*.p12';                     Sev = 'BLOCKER'; Desc = 'PKCS#12 密钥库' },
  @{ Glob = '*.pfx';                     Sev = 'BLOCKER'; Desc = 'PKCS#12 密钥库' },
  @{ Glob = '*.jks';                     Sev = 'BLOCKER'; Desc = 'Java 密钥库' },
  @{ Glob = '*.keystore';                Sev = 'BLOCKER'; Desc = '密钥库' },
  @{ Glob = 'id_rsa';                    Sev = 'BLOCKER'; Desc = 'SSH 私钥' },
  @{ Glob = 'id_rsa*';                   Sev = 'BLOCKER'; Desc = 'SSH 私钥' },
  @{ Glob = 'id_ed25519*';               Sev = 'BLOCKER'; Desc = 'SSH 私钥' },
  @{ Glob = 'id_ecdsa*';                 Sev = 'BLOCKER'; Desc = 'SSH 私钥' },
  @{ Glob = '.netrc';                    Sev = 'BLOCKER'; Desc = 'netrc 凭据文件' },
  @{ Glob = '_netrc';                    Sev = 'BLOCKER'; Desc = 'netrc 凭据文件' },
  @{ Glob = '.npmrc';                    Sev = 'BLOCKER'; Desc = 'npm 凭据文件（常含 _authToken）' },
  @{ Glob = '.pypirc';                   Sev = 'BLOCKER'; Desc = 'PyPI 凭据文件' },
  @{ Glob = '.git-credentials';          Sev = 'BLOCKER'; Desc = 'git 明文凭据' },
  @{ Glob = '.git-secrets.local';        Sev = 'BLOCKER'; Desc = '本 skill 的凭据文件' },
  @{ Glob = 'github.env';                Sev = 'BLOCKER'; Desc = '本 skill 的凭据文件' },
  @{ Glob = 'credentials*.json';         Sev = 'BLOCKER'; Desc = 'GCP/服务账号凭据' },
  @{ Glob = 'serviceAccount*.json';      Sev = 'BLOCKER'; Desc = 'GCP 服务账号凭据' },
  @{ Glob = '*.tfstate';                 Sev = 'BLOCKER'; Desc = 'Terraform state（常含明文密钥）' },
  @{ Glob = '*.tfstate.backup';          Sev = 'BLOCKER'; Desc = 'Terraform state 备份' },
  @{ Glob = '*.jwk';                     Sev = 'WARN';    Desc = 'JWK 密钥材料' },
  @{ Glob = '*.ovpn';                    Sev = 'WARN';    Desc = 'OpenVPN 配置（常含内嵌凭据）' },
  @{ Glob = '.env.example';              Sev = 'WARN';    Desc = '环境变量模板（确认里面只有占位符）' },
  @{ Glob = '.env.sample';               Sev = 'WARN';    Desc = '环境变量模板（确认里面只有占位符）' },
  @{ Glob = '.env.template';             Sev = 'WARN';    Desc = '环境变量模板（确认里面只有占位符）' },
  @{ Glob = 'appsettings.Development.json'; Sev = 'WARN'; Desc = '.NET 开发配置（常含连接串）' },
  @{ Glob = 'local.settings.json';       Sev = 'WARN';    Desc = 'Azure Functions 本地设置' },
  @{ Glob = '*.rdp';                     Sev = 'WARN';    Desc = 'RDP 文件' }
)

$skipDirNames = @('.git', 'node_modules', 'dist', 'build', 'out', 'target', 'vendor',
                  '.venv', 'venv', 'env', '__pycache__', '.next', '.nuxt', 'coverage',
                  '.cache', '.idea', '.vscode', 'bin', 'obj', 'Pods', '.gradle',
                  '.terraform', '.svn', '.hg', '.history', 'tmp', 'temp', '.pytest_cache',
                  '.mypy_cache', '.ruff_cache', '.tox', '.dart_tool', 'DerivedData',
                  '.dsh-release')

$textExt = @('.txt', '.md', '.markdown', '.rst', '.adoc', '.json', '.jsonc', '.json5', '.yml', '.yaml',
             '.toml', '.ini', '.cfg', '.conf', '.properties', '.env', '.xml', '.html', '.htm', '.css',
             '.scss', '.less', '.js', '.mjs', '.cjs', '.jsx', '.ts', '.tsx', '.mts', '.cts', '.vue',
             '.svelte', '.py', '.pyi', '.rb', '.php', '.java', '.kt', '.kts', '.scala', '.groovy',
             '.go', '.rs', '.c', '.h', '.cc', '.cpp', '.hpp', '.cs', '.fs', '.vb', '.swift', '.m',
             '.mm', '.dart', '.lua', '.pl', '.pm', '.r', '.jl', '.sh', '.bash', '.zsh', '.fish',
             '.ps1', '.psm1', '.psd1', '.bat', '.cmd', '.sql', '.graphql', '.gql', '.proto', '.tf',
             '.tfvars', '.hcl', '.dockerfile', '.gradle', '.cmake', '.mk', '.makefile', '.gitignore',
             '.gitattributes', '.dockerignore', '.npmignore', '.editorconfig', '.lock', '.sum', '.mod')

$binaryExt = @('.exe', '.dll', '.so', '.dylib', '.a', '.lib', '.class', '.jar', '.war', '.pyc',
               '.o', '.obj', '.bin', '.dat', '.db', '.sqlite', '.iso', '.msi', '.apk', '.ipa',
               # 常见二进制：不列全的话，未知扩展名改走内容嗅探后会被当文本读
               '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.ico', '.webp', '.tif', '.tiff', '.psd',
               '.zip', '.tar', '.gz', '.tgz', '.bz2', '.xz', '.7z', '.rar',
               '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
               '.woff', '.woff2', '.ttf', '.otf', '.eot',
               '.mp3', '.mp4', '.avi', '.mov', '.wav', '.webm', '.wasm', '.node', '.pdb')

$sentinelNames = @('.env', '.env.local', '.env.production', '.env.development', '.env.test', '.envrc')
$scriptExt = @('.ps1', '.psm1', '.sh', '.bash', '.bat', '.cmd')

# ── 收集待扫描文件 ──────────────────────────────────────────────────────────
$files = New-Object System.Collections.Generic.List[object]
# 被 -Ignore 排除的文件数。只统计不报错，但要打印出来：静默排除会让报告失去可信度。
$skippedIgnore = 0

function Test-SkipDir {
  param([string]$Name)
  if ($skipDirNames -contains $Name) { return $true }
  foreach ($ig in $Ignore) { if ($Name -like $ig) { return $true } }
  return $false
}

function Add-File {
  param([string]$FullPath)
  $trimmed = $FullPath.TrimEnd('\', '/')
  $rel = if ($trimmed -eq $root) { '' } else { $trimmed.Substring($root.Length).TrimStart('\', '/') }
  $relSlash = $rel -replace '\\', '/'
  $name = [System.IO.Path]::GetFileName($FullPath)
  # -Ignore 必须在这里生效，且必须同时管住「文件」：
  #   · Test-SkipDir 只在目录遍历时被调用，且只拿到目录名 —— 拦不住被命中的文件；
  #   · -StagedOnly 模式根本不走进目录遍历，靠 Test-SkipDir 等于 -Ignore 完全失效。
  # 相对路径（正/反斜杠两种写法都认）或文件名命中任一模式即排除。
  foreach ($ig in $Ignore) {
    if ($rel -like $ig -or $relSlash -like $ig -or $name -like $ig) { $script:skippedIgnore++; return }
  }
  $files.Add([pscustomobject]@{
    Full = $FullPath
    Rel  = $relSlash
    Name = $name
    Ext  = [System.IO.Path]::GetExtension($FullPath).ToLowerInvariant()
    Outside = (-not (($trimmed -eq $root) -or $trimmed.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase)))
  })
}

if ($StagedOnly) {
  # 顶层语句执行（不能在函数里，见 github-git.ps1 头部说明）
  cmd.exe /c $lsCap.CommandLine
  $lr = Get-Capture -Capture $lsCap
  if (-not $lr.Ok) { Write-Error "git ls-files 失败（确认 $root 是 git 仓库）: $($lr.StdErr)"; exit 1 }
  foreach ($f in $lr.Lines) {
    if ([string]::IsNullOrWhiteSpace($f)) { continue }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $full = Join-Path $root ($f -replace '/', $sep)
    if (Test-Path -LiteralPath $full -PathType Leaf) { Add-File -FullPath $full }
  }
} else {
  $stack = New-Object System.Collections.Stack
  $stack.Push($root)
  while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    $entries = $null
    try { $entries = Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop } catch { continue }
    foreach ($e in $entries) {
      if ($e -is [System.IO.DirectoryInfo]) {
        if (Test-SkipDir -Name $e.Name) { continue }
        if ($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        # junction / symlink 不跟进，避免扫描越出项目范围
        if ($e.LinkType) { continue }
        $stack.Push($e.FullName)
        continue
      }
      if ($e -is [System.IO.FileInfo]) {
        $isScript = $scriptExt -contains $e.Extension.ToLowerInvariant()
        if ($isScript -and $e.Length -gt 1MB) { continue }   # 大脚本多半是生成物/依赖
        if (Test-SelfPath -Path $e.FullName) { $skippedSelf++; continue }
        Add-File -FullPath $e.FullName
      }
    }
  }
}

# ── 文件名规则匹配 ─────────────────────────────────────────────────────────
function Test-FileRule {
  param([string]$Name)
  foreach ($r in $fileRules) {
    $hit = $false
    if ($r.Glob.StartsWith('*') -and $r.Glob.IndexOf('*', 1) -lt 0) {
      $hit = ($Name.ToLowerInvariant().EndsWith($r.Glob.Substring(1).ToLowerInvariant()))
    } else {
      $hit = ($Name -like $r.Glob) -or ($Name.ToLowerInvariant() -eq $r.Glob.ToLowerInvariant())
    }
    if (-not $hit) { continue }
    if ($r.ContainsKey('Except') -and ($r.Except -contains $Name)) {
      # 明确列出的模板文件改判为 WARN
      return @{ Id = 'file-pattern'; Sev = 'WARN'; Desc = "$($r.Desc)（模板文件，请确认内容只有占位符）" }
    }
    return @{ Id = 'file-pattern'; Sev = $r.Sev; Desc = $r.Desc }
  }
  return $null
}

function Test-IsText {
  param([string]$Full, [string]$Ext, [string]$Name)
  if ($textExt -contains $Ext) { return $true }
  if ($sentinelNames -contains $Name) { return $true }
  if ($Name -in @('Dockerfile', 'Makefile', 'Procfile', 'Gemfile', 'Rakefile')) { return $true }
  if ($binaryExt -contains $Ext) { return $false }
  # 未知扩展名**不能**直接假定为二进制：那样 .template / .example / .sample / .dist
  # 这类「模板文件」会被静默跳过 —— 而它们恰恰是最可能装着待填凭据的一类文件
  # （本 skill 自己的 assets/github-env.template 就这么被漏扫过）。
  # 改为嗅探内容：前 1024 字节里有 NUL 就当二进制，否则当文本。
  try {
    $fs = [System.IO.File]::OpenRead($Full)
    try {
      $buf = New-Object byte[] 1024
      $n = $fs.Read($buf, 0, 1024)
      for ($i = 0; $i -lt $n; $i++) { if ($buf[$i] -eq 0) { return $false } }
      return $true
    } finally { $fs.Dispose() }
  } catch { return $false }
}

function Get-Masked {
  param([string]$Value)
  $v = $Value.Trim()
  if ($v.Length -gt 140) { $v = $v.Substring(0, 140) + '…' }
  $v = $v -replace '\s+', ' '
  if ($NoMask) { return $v }
  if ($v.Length -le 6) { return ('*' * $v.Length) }
  if ($v.Length -le 14) { return $v.Substring(0, 2) + ('*' * ($v.Length - 2)) }
  return $v.Substring(0, 4) + ('*' * 8) + $v.Substring($v.Length - 3)
}

# ── 扫描 ────────────────────────────────────────────────────────────────────
$findings = New-Object System.Collections.Generic.List[object]
function Add-Finding {
  param([string]$Sev, [string]$Rule, [string]$Desc, [string]$Rel, [int]$Line, [string]$Snippet)
  if ($findings.Count -ge $MaxHits) { return }
  $findings.Add([pscustomobject]@{
    Severity = $Sev
    Rule     = $Rule
    Desc     = $Desc
    File     = $Rel
    Line     = $Line
    Snippet  = (Get-Masked -Value $Snippet)
  })
}

$maxBytes = $MaxFileMB * 1MB
$scannedFiles = 0
$skippedBinary = 0
$skippedLarge = 0

foreach ($f in $files) {
  # 规则 1：本 skill 自身目录永不扫描（里面写的是检测规则字符串，不是泄漏）
  if ($f.Outside) { continue }

  $fr = Test-FileRule -Name $f.Name
  if ($fr) { Add-Finding -Sev $fr.Sev -Rule $fr.Id -Desc $fr.Desc -Rel $f.Rel -Line 0 -Snippet ('文件: ' + $f.Rel) }

  if (-not (Test-IsText -Full $f.Full -Ext $f.Ext -Name $f.Name)) { $skippedBinary++; continue }
  $len = 0
  try { $len = (Get-Item -LiteralPath $f.Full -Force).Length } catch { continue }
  if ($len -gt $maxBytes) { $skippedLarge++; continue }

  $scannedFiles++
  $lineNo = 0
  try {
    foreach ($line in [System.IO.File]::ReadLines($f.Full)) {
      $lineNo++
      if ($line.Length -eq 0 -or $line.Length -gt 4000) { continue }
      foreach ($rule in $rules) {
        $m = [regex]::Match($line, $rule.Re)
        if (-not $m.Success) { continue }
        $val = $m.Value
        # 只凭匹配值判断占位符；命中占位符的 BLOCKER 降级为 INFO，不阻塞推送。
        if ($val -match $placeholderRe -or $val -match $placeholderValueRe) {
          if ($rule.Sev -eq 'BLOCKER') {
            Add-Finding -Sev 'INFO' -Rule ($rule.Id + '-placeholder') -Desc ($rule.Desc + '（疑似占位符）') -Rel $f.Rel -Line $lineNo -Snippet $val
          }
          break
        }
        Add-Finding -Sev $rule.Sev -Rule $rule.Id -Desc $rule.Desc -Rel $f.Rel -Line $lineNo -Snippet $val
        break   # 一行只报最靠前的一条规则，避免刷屏
      }
    }
  } catch { continue }
}

$blockers = @($findings | Where-Object { $_.Severity -eq 'BLOCKER' })
$warns    = @($findings | Where-Object { $_.Severity -eq 'WARN' })
$infos    = @($findings | Where-Object { $_.Severity -eq 'INFO' })

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('=== 敏感信息扫描报告 ===')
$lines.Add("项目      : $root")
$lines.Add("模式      : " + $(if ($StagedOnly) { '仅已暂存文件' } else { '全部文件（排除 .git/node_modules 等）' }))
$lines.Add("扫描文件数: $scannedFiles  跳过二进制: $skippedBinary  跳过超大: $skippedLarge" + $(if ($skippedSelf -gt 0) { "  跳过技能自身: $skippedSelf" } else { '' }) + $(if ($skippedIgnore -gt 0) { "  按 -Ignore 排除: $skippedIgnore" } else { '' }))
$lines.Add("结论      : BLOCKER=$($blockers.Count)  WARN=$($warns.Count)  INFO=$($infos.Count)")
$lines.Add('')
if ($blockers.Count -gt 0) {
  $lines.Add('【BLOCKER】必须处理，否则不要推送：')
  foreach ($b in $blockers) { $lines.Add("  [!] $($b.File):$($b.Line)  [$($b.Rule)] $($b.Desc)  →  $($b.Snippet)") }
  $lines.Add('')
}
if ($warns.Count -gt 0) {
  $lines.Add('【WARN】请人工确认：')
  foreach ($w in $warns) { $lines.Add("  [?] $($w.File):$($w.Line)  [$($w.Rule)] $($w.Desc)  →  $($w.Snippet)") }
  $lines.Add('')
}
if ($infos.Count -gt 0) {
  $lines.Add('【INFO】疑似占位符，通常可忽略：')
  $n = 0
  foreach ($i in $infos) { if ($n -ge 25) { $lines.Add("  ...（其余 $($infos.Count - 25) 条略）"); break }; $lines.Add("  [i] $($i.File):$($i.Line)  [$($i.Rule)]  →  $($i.Snippet)"); $n++ }
  $lines.Add('')
}
if ($blockers.Count -eq 0 -and $warns.Count -eq 0) {
  $lines.Add('未发现敏感信息风险。')
  $lines.Add('')
}
$lines.Add('注意：本报告只输出掩码片段。命中的文件请勿用 cat / Get-Content 直接读进对话。')
$text = ($lines -join [Environment]::NewLine)

if ($ReportPath) {
  $dir = Split-Path -Parent $ReportPath
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  Set-Content -LiteralPath $ReportPath -Value $text -Encoding UTF8
}

if ($Json) {
  $obj = [ordered]@{
    root = $root
    stagedOnly = [bool]$StagedOnly
    scanned = $scannedFiles
    skippedBinary = $skippedBinary
    skippedLarge = $skippedLarge
    skippedIgnore = $skippedIgnore
    blockerCount = $blockers.Count
    warnCount = $warns.Count
    infoCount = $infos.Count
    blockers = $blockers
    warns = $warns
    reportPath = $ReportPath
  }
  $obj | ConvertTo-Json -Depth 5
} else {
  Write-Output $text
}

if ($blockers.Count -gt 0) { exit 3 } else { exit 0 }
