<#
github-git.ps1 —— 共享助手：在受限执行环境里调用外部命令并取回输出与退出码。

实测边界（务必先读）:
  在 DSH 沙箱（workspace-write）下，下面这些写法**都会失败**，因为它们都要给
  子进程建立管道或重定向句柄，而沙箱不允许：
      $out = & git status                     → StandardOutputEncoding 报错
      & git status > file                     → 同上（PowerShell 的 ">" 也是管道）
      cmd.exe /c ... > file（在 dot-source 进来的函数里调用）→ 同上
      [Diagnostics.Process]::Start(...RedirectStandardOutput = $true) → 拒绝访问
      Start-Process -RedirectStandardOutput → 拒绝访问
      & pwsh -File inner.ps1                  → 同上（pwsh 作为子进程也被拒）
  **可用**的组合只有一种：
      调用方脚本的顶层语句   +   cmd.exe /c "... > log 2>&1 & echo __DSH_EXIT__%ERRORLEVEL% >> log"
  也就是说：谁要输出，谁就得在**自己的顶层**写这条命令；把它包进 dot-source 的函数里
  再调用，就会退回被拒的那条路径。

因此本文件只提供「不碰子进程」的纯构造与解析工具，实际调用由调用方顶层完成：

    . "$PSScriptRoot\github-git.ps1"
    $cap = New-Capture -WorkDir $root
    cmd.exe /c $cap.CommandLine          # ← 必须是调用方顶层语句
    $r = Get-Capture -Capture $cap       # → @{ Ok; ExitCode; StdOut; Lines; StdErr }

在不受限环境里，调用方顶层语句同样工作，不需要分支。
#>

function ConvertTo-ArgString {
  <#
  .SYNOPSIS
    把参数数组拼成 Windows 命令行字符串（按 Windows 规则转义）。
  #>
  param([string[]]$Arguments)
  $parts = @()
  foreach ($a in $Arguments) {
    if ($null -eq $a) { $parts += '""'; continue }
    $s = [string]$a
    if ($s -eq '') { $parts += '""'; continue }
    if ($s -notmatch '[\s"]') { $parts += $s; continue }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $s.ToCharArray()) {
      if ($ch -eq '\') { $bs++; continue }
      if ($ch -eq '"') { [void]$sb.Append('\' * ($bs * 2 + 1)); [void]$sb.Append('"'); $bs = 0; continue }
      if ($bs -gt 0) { [void]$sb.Append('\' * $bs); $bs = 0 }
      [void]$sb.Append($ch)
    }
    if ($bs -gt 0) { [void]$sb.Append('\' * ($bs * 2)) }
    [void]$sb.Append('"')
    $parts += $sb.ToString()
  }
  return ($parts -join ' ')
}

function New-CapturePlan {
  <#
  .SYNOPSIS
    只构造捕获计划，不碰文件系统（纯函数）。
  .DESCRIPTION
    拆出纯构造的原因：New-Capture 要往工作目录写 .bat，而工作目录可能**不可写**
    （典型场景：用本 skill 扫描 skill 自己的安装目录）。纯构造不会因不可写而抛异常。

    为什么必须用 .bat 包装:
      · PowerShell 的 ">" 会给子进程开管道，受限环境直接拒绝。
      · cmd 的 "cmd /c ... & echo %ERRORLEVEL%" 里 %ERRORLEVEL% 在**解析期**就展开了，
        拿到的是命令执行前的旧值，退出码永远不可信。
      · .bat 里的 ERRORLEVEL 在运行时求值，才是真退出码。
      · 参数经 ConvertTo-ArgString 转义，可安全处理引号与空格。

    日志写在「工作目录内的 .dsh-release\.run」而不是系统 temp —— 受限环境里子进程
    写不进 temp。.dsh-release 必须写进 .gitignore。
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string[]]$Arguments = @(),
    [string]$WorkDir = (Get-Location).Path
  )
  if (-not (Test-Path -LiteralPath $WorkDir)) { $WorkDir = (Get-Location).Path }
  $runDir = Join-Path $WorkDir '.dsh-release\.run'
  $tag = [guid]::NewGuid().ToString('N')
  $logFile = Join-Path $runDir "$tag.log"
  $batFile = Join-Path $runDir "$tag.cmd"
  # 批处理里 % 是变量引用符，必须转义成 %%（git 的 --pretty=%H 之类参数会踩到）
  $argsStr = (ConvertTo-ArgString -Arguments $Arguments) -replace '%', '%%'

  $bat = @(
    '@echo off',
    'setlocal',
    ('cd /d "' + $WorkDir + '"'),
    ('"' + $Exe + '" ' + $argsStr + ' > "' + $logFile + '" 2>&1'),
    ('>> "' + $logFile + '" echo __DSH_EXIT__%ERRORLEVEL%')
  ) -join "`r`n"

  return [pscustomobject]@{
    CommandLine = ('cmd.exe /c "' + $batFile + '"')
    LogFile     = $logFile
    BatFile     = $batFile
    WorkDir     = $WorkDir
    RunDir      = $runDir
    Exe         = $Exe
    Args        = $argsStr
    BatText     = $bat + "`r`n"
  }
}

function New-Capture {
  <#
  .SYNOPSIS
    构造捕获计划并落盘 .bat：返回 @{ CommandLine; LogFile; BatFile; ... }。
  .DESCRIPTION
    工作目录**不可写**时（典型场景：扫描本 skill 自己的安装目录）会抛异常。
    那种情况下改用 New-CapturePlan 纯构造，由调用方决定是否降级。

    拿到结果后必须由调用方在**自己的顶层**执行：cmd.exe /c $cap.CommandLine
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string[]]$Arguments = @(),
    [string]$WorkDir = (Get-Location).Path
  )
  $plan = New-CapturePlan -Exe $Exe -Arguments $Arguments -WorkDir $WorkDir
  New-Item -ItemType Directory -Force -Path $plan.RunDir -ErrorAction Stop | Out-Null
  # 必须 UTF-8 无 BOM：项目路径常含中文，用 ASCII 写会把路径变成 "????" 而报
  # "The filename, directory name, or volume label syntax is incorrect."
  # cmd.exe 能正确执行无 BOM 的 UTF-8 批处理。
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($plan.BatFile, $plan.BatText, $utf8NoBom)
  return $plan
}

function Get-Capture {
  <#
  .SYNOPSIS
    读取 New-Capture 的结果，返回 @{ Ok; ExitCode; StdOut; Lines; StdErr }。
  .DESCRIPTION
    命令执行后调用即可；会轮询等待 __DSH_EXIT__ 哨兵行出现（默认最多 120 秒）。
    读完后清理日志文件。
  #>
  param(
    [Parameter(Mandatory = $true)]$Capture,
    [int]$TimeoutMs = 120000,
    [switch]$KeepArtifacts
  )
  $logFile = $Capture.LogFile
  $batFile = $Capture.BatFile
  $cleanup = {
    if (-not $KeepArtifacts) {
      Remove-Item -LiteralPath $logFile, $batFile -Force -ErrorAction SilentlyContinue
    }
  }
  $deadline = (Get-Date).AddMilliseconds([math]::Max($TimeoutMs, 1000))
  $raw = $null
  while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $logFile) {
      $probe = Get-Content -LiteralPath $logFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
      if ($probe -and ($probe -match '__DSH_EXIT__-?\d+\s*$')) { $raw = $probe; break }
    }
    Start-Sleep -Milliseconds 25
  }

  $out = [pscustomobject]@{
    Ok       = $false
    ExitCode = -1
    StdOut   = ''
    StdErr   = ''
    Lines    = @()
  }

  if ($null -eq $raw) {
    if (Test-Path -LiteralPath $logFile) {
      $out.StdErr = "命令未产出退出码（日志: $logFile）"
      & $cleanup
    } else {
      $out.StdErr = "命令未执行或日志缺失: $($Capture.CommandLine)"
    }
    return $out
  }

  & $cleanup
  $raw = $raw.TrimEnd("`r", "`n")
  $body = $raw
  $exit = -1
  $m = [regex]::Match($raw, '__DSH_EXIT__(-?\d+)\s*$')
  if ($m.Success) {
    $exit = [int]$m.Groups[1].Value
    $body = $raw.Substring(0, $m.Index).TrimEnd("`r", "`n")
  }
  $out.ExitCode = $exit
  $out.Ok = ($exit -eq 0)
  $out.StdOut = $body
  $out.Lines = if ($body -eq '') { @() } else { @($body -split "`r?`n") }
  return $out
}

function Invoke-Git {
  <#
  .SYNOPSIS
    在调用方顶层完成「生成包装 → 执行 → 读取」的简写，等价于：
        $cap = New-Capture -Exe git -Arguments $a -WorkDir $wd
        cmd.exe /c $cap.CommandLine
        Get-Capture -Capture $cap
  .DESCRIPTION
    **必须由调用方脚本的顶层语句直接执行本函数**，用来一次性完成三步。
    不要把它再包进别的函数——受限环境会拒绝「dot-source 进来的函数里启动子进程」
    这条路径，包一层就会退回被拒的写法。同理，本函数自身不能再被别人包装。
  #>
  param(
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [string]$WorkingDirectory = (Get-Location).Path,
    [int]$TimeoutMs = 120000,
    [switch]$KeepArtifacts
  )
  $cap = New-Capture -Exe 'git' -Arguments $Arguments -WorkDir $WorkingDirectory
  cmd.exe /c $cap.CommandLine
  return Get-Capture -Capture $cap -TimeoutMs $TimeoutMs -KeepArtifacts:$KeepArtifacts
}
