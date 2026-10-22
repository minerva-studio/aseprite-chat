param([Parameter(Mandatory = $true)][string]$ResultPath, [string]$ExtensionRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'


# Only a live, idle bridge with the exact protocol identity can be reused.
# Discovery is a hint; its pid must still match the server at the hinted port.
function Get-IdleEndpoint($Port, $ExpectedPid = $null) {
  if (($Port -isnot [int] -and $Port -isnot [long]) -or $Port -lt 1 -or $Port -gt 65535) { return $null }
  try {
    $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/readyz" -UseBasicParsing -TimeoutSec 1 -ErrorAction Stop
    if ($health.service -ceq 'aseprite-chat' -and
        ($health.protocolVersion -is [int] -or $health.protocolVersion -is [long]) -and $health.protocolVersion -eq 2 -and
        ($health.pid -is [int] -or $health.pid -is [long]) -and $health.pid -gt 0 -and
        ($health.port -is [int] -or $health.port -is [long]) -and $health.port -eq $Port -and
        $health.busy -is [bool] -and $health.busy -eq $false -and
        ($null -eq $ExpectedPid -or $health.pid -eq $ExpectedPid)) {
      return "ws://127.0.0.1:$Port"
    }
  } catch { }
  return $null
}

function Find-NativeExecutable([string]$Name, [string[]]$Candidates) {
  $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($command -and [IO.Path]::GetExtension($command.Source) -ieq '.exe' -and [IO.File]::Exists($command.Source)) {
    return [IO.Path]::GetFullPath($command.Source)
  }
  foreach ($candidate in $Candidates) {
    if ($candidate -and [IO.File]::Exists($candidate)) { return [IO.Path]::GetFullPath($candidate) }
  }
  return $null
}

# Result publication is atomic so Lua never treats a partly written error as a
# completed response. The caller owns its unique result path, not discovery.
function Write-Result($Value) {
  $temporaryPath = $ResultPath + '.' + [guid]::NewGuid().ToString() + '.tmp'
  try {
    [IO.File]::WriteAllText($temporaryPath, ($Value | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $ResultPath -Force
  } finally {
    if ([IO.File]::Exists($temporaryPath)) { Remove-Item -LiteralPath $temporaryPath -Force }
  }
}

try {
  if (-not $env:LOCALAPPDATA) { throw '无法确定本机用户数据目录。请重新登录 Windows 后重试。' }
  $discoveryPath = Join-Path $env:LOCALAPPDATA 'AsepriteChat/bridge.json'
  $endpoint = $null
  if ([IO.File]::Exists($discoveryPath)) {
    try {
      $hint = Get-Content -LiteralPath $discoveryPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if (($hint.pid -is [int] -or $hint.pid -is [long]) -and $hint.pid -gt 0) {
        $endpoint = Get-IdleEndpoint $hint.port $hint.pid
      }
    } catch { }
  }
  if (-not $endpoint) { $endpoint = Get-IdleEndpoint 4500 }
  if ($endpoint) { Write-Result @{endpoint=$endpoint}; return }

  $nodeCandidates = @()
  foreach ($programRoot in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if ($programRoot) { $nodeCandidates += Join-Path $programRoot 'nodejs/node.exe' }
  }
  $nodeCandidates += Join-Path $env:LOCALAPPDATA 'Programs/nodejs/node.exe'
  $nodeCandidates += Join-Path $env:LOCALAPPDATA 'nodejs/node.exe'
  $node = Find-NativeExecutable 'node.exe' $nodeCandidates
  if (-not $node) { throw '未找到 Node.js。请安装 Node.js 24 或更新版本，重新打开 Aseprite 后重试。' }
  $version = & $node --version 2>$null
  if ($LASTEXITCODE -ne 0 -or $version -notmatch '^v(\d+)\.' -or [int]$Matches[1] -lt 24) {
    throw 'Node.js 版本不受支持。请安装 Node.js 24 或更新版本，重新打开 Aseprite 后重试。'
  }
  $codex = Find-NativeExecutable 'codex.exe' @((Join-Path $env:LOCALAPPDATA 'Programs/OpenAI/Codex/bin/codex.exe'))
  if (-not $codex) {
    # A shell wrapper is only a location hint. Never execute it or pass it to
    # Node's shell-free spawn; inspect only known native npm package layouts.
    $packageRoots = @()
    $wrapper = Get-Command -Name 'codex.cmd' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($wrapper -and [IO.Path]::GetExtension($wrapper.Source) -ieq '.cmd') {
      $packageRoots += Join-Path (Split-Path -Parent $wrapper.Source) 'node_modules/@openai'
    }
    if ($env:APPDATA) { $packageRoots += Join-Path $env:APPDATA 'npm/node_modules/@openai' }
    foreach ($packageRoot in $packageRoots) {
      foreach ($relativePath in @(
          'codex/node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/bin/codex.exe',
          'codex-win32-x64/vendor/x86_64-pc-windows-msvc/bin/codex.exe')) {
        $candidate = Join-Path $packageRoot $relativePath
        if ([IO.File]::Exists($candidate)) { $codex = [IO.Path]::GetFullPath($candidate); break }
      }
      if ($codex) { break }
    }
  }
  if (-not $codex) { throw '未找到原生 Codex 程序。请安装 Codex 桌面版或修复 Codex CLI 安装并登录，重新打开 Aseprite 后重试。' }
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $discoveryPath))

  # Windows PowerShell 5.1 has no Start-Process -Environment. Set these only in
  # this bootstrap process for child inheritance, then restore them even on error.
  $childEnvironment = @{
    CODEX_CLI=$codex
    ASEPRITE_CHAT_PORT='0'
    ASEPRITE_CHAT_READY_FILE=[IO.Path]::GetFullPath($ResultPath)
    ASEPRITE_CHAT_DISCOVERY_FILE=$discoveryPath
    ASEPRITE_CHAT_IDLE_TIMEOUT_MS='120000'
  }
  $previousEnvironment = @{}
  try {
    foreach ($name in $childEnvironment.Keys) {
      $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
      [Environment]::SetEnvironmentVariable($name, $childEnvironment[$name], 'Process')
    }
    $serverPath = Join-Path $ExtensionRoot 'scripts/server.mjs'
    # Start-Process invokes native node.exe directly. Only its one file argument
    # needs Windows argv quoting; no cmd/start shell ever receives these paths.
    Start-Process -FilePath $node -ArgumentList ('"' + $serverPath + '"') `
      -WorkingDirectory $extensionRoot -WindowStyle Hidden -ErrorAction Stop | Out-Null
  } finally {
    foreach ($name in $previousEnvironment.Keys) {
      [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
    }
  }
} catch {
  Write-Result @{error=("自动连接失败：" + $_.Exception.Message + ' 请确认已允许 Aseprite 访问文件和启动进程，然后重试。')}
}
