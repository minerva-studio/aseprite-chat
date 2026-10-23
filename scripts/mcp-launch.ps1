param(
  [Parameter(Mandatory = $true)][string]$ResultPath,
  [string]$ExtensionRoot = (Split-Path -Parent $PSScriptRoot),
  [Parameter(Mandatory = $true)][string]$CodexHome,
  [switch]$ConnectOnly
)
$ErrorActionPreference = 'Stop'

# Start-Process joins ArgumentList into one native command line on WinPS 5.1.
# Quote by the Windows argv rules, including backslashes preceding quotes/end.
function ConvertTo-NativeArgument([string]$Value) {
  $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
  $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
  return '"' + $escaped + '"'
}

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
  $node = $null
  $command = Get-Command -Name 'node.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($command -and [IO.Path]::GetExtension($command.Source) -ieq '.exe' -and [IO.File]::Exists($command.Source)) {
    $node = [IO.Path]::GetFullPath($command.Source)
  }
  $candidates = @()
  foreach ($programRoot in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if ($programRoot) { $candidates += Join-Path $programRoot 'nodejs/node.exe' }
  }
  if ($env:LOCALAPPDATA) {
    $candidates += Join-Path $env:LOCALAPPDATA 'Programs/nodejs/node.exe'
    $candidates += Join-Path $env:LOCALAPPDATA 'nodejs/node.exe'
  }
  if (-not $node) {
    foreach ($candidate in $candidates) {
      if ([IO.File]::Exists($candidate)) { $node = [IO.Path]::GetFullPath($candidate); break }
    }
  }
  if (-not $node) { throw '未找到 Node.js。请安装 Node.js 24 或更新版本后重试。' }
  $version = & $node --version 2>$null
  if ($LASTEXITCODE -ne 0 -or $version -notmatch '^v(\d+)\.' -or [int]$Matches[1] -lt 24) {
    throw 'Node.js 版本不受支持。请安装 Node.js 24 或更新版本后重试。'
  }
  $helper = Join-Path $ExtensionRoot 'scripts/register-mcp.mjs'
  $nativeArguments = @($helper, '--home', $CodexHome, '--root', $ExtensionRoot, '--result', $ResultPath)
  if ($ConnectOnly) { $nativeArguments += '--connect-only' }
  $argumentLine = ($nativeArguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
  # No cmd/PowerShell interpolation receives user paths. The helper selects
  # CODEX_HOME only for its Codex children; this process environment is untouched.
  Start-Process -FilePath $node -ArgumentList $argumentLine -WorkingDirectory $ExtensionRoot `
    -WindowStyle Hidden -ErrorAction Stop | Out-Null
} catch {
  # Fixed diagnostics avoid leaking arbitrary process/configuration contents.
  Write-Result @{error='无法启动 MCP 连接。请确认已安装 Node.js 24 或更新版本，并允许 Aseprite 启动进程。'}
}
