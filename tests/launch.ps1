param()
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/launch.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) { throw 'Automatic bootstrap is not implemented' }

$nativeNode = (Get-Command node.exe -CommandType Application).Source
$nativeCodex = (Get-Command codex.exe -CommandType Application).Source
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("aseprite-launch 中文 ' 100% & `$() " + [guid]::NewGuid())
$ownedProcesses = [Collections.Generic.List[object]]::new()
$savedEnvironment = @{}
foreach ($name in @('LOCALAPPDATA', 'APPDATA', 'ProgramFiles', 'ProgramFiles(x86)', 'CODEX_CLI', 'ASEPRITE_CHAT_PORT',
    'ASEPRITE_CHAT_READY_FILE', 'ASEPRITE_CHAT_DISCOVERY_FILE', 'ASEPRITE_CHAT_IDLE_TIMEOUT_MS')) {
  $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$passed = 0
$tests = 0
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-Json([string]$Path, $Value) {
  [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
}
function Healthy([int]$Port = 45121, [int]$ProcessId = 12345) {
  return @{service='aseprite-chat'; protocolVersion=1; pid=$ProcessId; port=$Port; busy=$false}
}
function Reset-Scenario {
  $global:asepriteLaunchScenario = @{responses=@{}; starts=@(); commands=@(); missingNode=$false; missingCodex=$false;
    real=$false; failStart=$false}
  $env:LOCALAPPDATA = Join-Path $testRoot ([guid]::NewGuid().ToString())
  $env:APPDATA = Join-Path $env:LOCALAPPDATA 'roaming'
  $env:ProgramFiles = Join-Path $env:LOCALAPPDATA 'programs'
  ${env:ProgramFiles(x86)} = Join-Path $env:LOCALAPPDATA 'programs-x86'
  [void][IO.Directory]::CreateDirectory((Join-Path $env:LOCALAPPDATA 'AsepriteChat'))
}
function Get-Command {
  param($Name, $CommandType, $ErrorAction)
  $global:asepriteLaunchScenario.commands += $Name
  if ($Name -eq 'node.exe' -and -not $global:asepriteLaunchScenario.missingNode) {
    return [pscustomobject]@{Source=$nativeNode; CommandType='Application'}
  }
  if ($Name -eq 'codex.exe' -and -not $global:asepriteLaunchScenario.missingCodex) {
    return [pscustomobject]@{Source=$nativeCodex; CommandType='Application'}
  }
  if ($Name -eq 'codex.cmd' -and $global:asepriteLaunchScenario.commandShim) {
    return [pscustomobject]@{Source=$global:asepriteLaunchScenario.commandShim; CommandType='Application'}
  }
}
function Invoke-RestMethod {
  param($Uri, $TimeoutSec, [switch]$UseBasicParsing, $ErrorAction)
  $key = [string]$Uri
  if ($global:asepriteLaunchScenario.responses.ContainsKey($key)) { return $global:asepriteLaunchScenario.responses[$key] }
  if ($global:asepriteLaunchScenario.real -and $key -notmatch ':4500/readyz$') {
    return Microsoft.PowerShell.Utility\Invoke-RestMethod -Uri $Uri -TimeoutSec $TimeoutSec -UseBasicParsing
  }
  throw 'Fixture endpoint is unavailable'
}
function Start-Process {
  param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle, [switch]$PassThru, $ErrorAction)
  $global:asepriteLaunchScenario.starts += @(@{file=$FilePath; arguments=$ArgumentList; cwd=$WorkingDirectory; window=$WindowStyle;
    codex=$env:CODEX_CLI; port=$env:ASEPRITE_CHAT_PORT; ready=$env:ASEPRITE_CHAT_READY_FILE;
    discovery=$env:ASEPRITE_CHAT_DISCOVERY_FILE; idle=$env:ASEPRITE_CHAT_IDLE_TIMEOUT_MS})
  if ($global:asepriteLaunchScenario.failStart) { throw 'Fixture process creation failed' }
  if ($global:asepriteLaunchScenario.real) {
    $process = Microsoft.PowerShell.Management\Start-Process -FilePath $FilePath -ArgumentList $ArgumentList `
      -WorkingDirectory $WorkingDirectory -WindowStyle $WindowStyle -PassThru
    $ownedProcesses.Add($process)
    return $process
  }
  Write-Json $env:ASEPRITE_CHAT_READY_FILE @{endpoint='ws://127.0.0.1:45123'}
}
function Bootstrap([string]$Script = $scriptPath) {
  $resultPath = Join-Path $env:LOCALAPPDATA ([guid]::NewGuid().ToString()+'.json')
  & $Script -ResultPath $resultPath
  $deadline = [DateTime]::UtcNow.AddSeconds(8)
  while (-not [IO.File]::Exists($resultPath) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
  Assert ([IO.File]::Exists($resultPath)) 'Bootstrap did not publish a result'
  return Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
function Test([string]$Name, [scriptblock]$Body) {
  $script:tests++
  Reset-Scenario
  & $Body
  $script:passed++
  Write-Host "PASS $Name"
}

try {
  [void][IO.Directory]::CreateDirectory($testRoot)
  Test 'validated idle discovery reuses a bridge without installed runtimes' {
    $global:asepriteLaunchScenario.missingNode=$true; $global:asepriteLaunchScenario.missingCodex=$true
    Write-Json (Join-Path $env:LOCALAPPDATA 'AsepriteChat/bridge.json') (Healthy)
    $global:asepriteLaunchScenario.responses['http://127.0.0.1:45121/readyz'] = [pscustomobject](Healthy)
    $result = Bootstrap
    Assert ($result.endpoint -eq 'ws://127.0.0.1:45121') ('Idle bridge was not reused: '+($result | ConvertTo-Json -Compress))
    Assert ($global:asepriteLaunchScenario.starts.Count -eq 0) 'Reuse launched another bridge'
  }
  Test 'stale discovery falls back to validated conventional endpoint' {
    Write-Json (Join-Path $env:LOCALAPPDATA 'AsepriteChat/bridge.json') (Healthy)
    $global:asepriteLaunchScenario.responses['http://127.0.0.1:45121/readyz'] = [pscustomobject](Healthy 45121 999)
    $global:asepriteLaunchScenario.responses['http://127.0.0.1:4500/readyz'] = [pscustomobject](Healthy 4500)
    $result = Bootstrap
    Assert ($result.endpoint -eq 'ws://127.0.0.1:4500') 'Stale pid was reused or fallback was skipped'
    Assert ($global:asepriteLaunchScenario.starts.Count -eq 0) 'Manual idle bridge should be reused'
  }
  Test 'malformed discovery cannot prevent conventional endpoint reuse' {
    [IO.File]::WriteAllText((Join-Path $env:LOCALAPPDATA 'AsepriteChat/bridge.json'), '{')
    $global:asepriteLaunchScenario.responses['http://127.0.0.1:4500/readyz'] = [pscustomobject](Healthy 4500)
    Assert ((Bootstrap).endpoint -eq 'ws://127.0.0.1:4500') 'Malformed hint blocked automatic connection'
  }
  Test 'foreign incompatible busy or malformed health cannot be stolen' {
    foreach ($mutation in @(@{service='other'}, @{protocolVersion=2}, @{protocolVersion='1'},
        @{busy=$true}, @{busy='false'}, @{busy=$null}, @{pid=0}, @{pid='12345'}, @{port=4500})) {
      Reset-Scenario
      Write-Json (Join-Path $env:LOCALAPPDATA 'AsepriteChat/bridge.json') (Healthy)
      $health=Healthy
      foreach ($key in $mutation.Keys) { $health[$key]=$mutation[$key] }
      $global:asepriteLaunchScenario.responses['http://127.0.0.1:45121/readyz']=[pscustomobject]$health
      $result=Bootstrap
      Assert ($global:asepriteLaunchScenario.starts.Count -eq 1) 'Invalid live identity or busy state was reused'
      Assert ($result.endpoint -eq 'ws://127.0.0.1:45123') 'New bridge result was lost'
    }
  }
  Test 'missing Node returns Chinese installation remedy without terminal setup' {
    $global:asepriteLaunchScenario.missingNode=$true
    $result=Bootstrap
    Assert ($result.error -match 'Node.js' -and $result.error -match '24' -and $result.error -match '安装') 'Missing Node remedy is incomplete'
    Assert ($global:asepriteLaunchScenario.starts.Count -eq 0) 'Started a bridge without Node'
  }
  Test 'missing native Codex has install remedy and desktop fallback is discovered' {
    $global:asepriteLaunchScenario.missingCodex=$true
    [IO.File]::WriteAllText((Join-Path $env:LOCALAPPDATA 'codex.cmd'), '@echo fixture')
    $result=Bootstrap
    Assert ($result.error -match 'Codex' -and $result.error -match '安装') 'Missing native Codex remedy is incomplete'
    $desktop=Join-Path $env:LOCALAPPDATA 'Programs/OpenAI/Codex/bin'
    [void][IO.Directory]::CreateDirectory($desktop)
    $native=Join-Path $desktop 'codex.exe'; [IO.File]::WriteAllText($native, 'fixture-native-path')
    $result=Bootstrap
    Assert ($global:asepriteLaunchScenario.starts[-1].codex -eq $native) 'Desktop native fallback was not selected'
  }
  Test 'npm command location and AppData resolve bounded native executable paths' {
    foreach ($location in @('command', 'appdata')) {
      Reset-Scenario
      $global:asepriteLaunchScenario.missingCodex=$true
      $npmRoot=if ($location -eq 'command') { Join-Path $env:LOCALAPPDATA "custom npm 中文 ' 100%" } else { Join-Path $env:APPDATA 'npm' }
      [void][IO.Directory]::CreateDirectory($npmRoot)
      if ($location -eq 'command') {
        $shim=Join-Path $npmRoot 'codex.cmd'
        [IO.File]::WriteAllText($shim,'@echo This wrapper must never execute')
        $global:asepriteLaunchScenario.commandShim=$shim
      }
      $packageRoot=Join-Path $npmRoot 'node_modules/@openai'
      $nativeDirectory=Join-Path $packageRoot 'codex/node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/bin'
      [void][IO.Directory]::CreateDirectory($nativeDirectory)
      $native=Join-Path $nativeDirectory 'codex.exe'; [IO.File]::WriteAllText($native,'fixture-native-path')
      $result=Bootstrap
      Assert ($result.endpoint -eq 'ws://127.0.0.1:45123') 'Native npm package was not discovered'
      Assert ($global:asepriteLaunchScenario.starts[-1].codex -eq $native) 'Native npm child path must not be a shell wrapper'
    }
  }
  Test 'ProgramFiles Node fallback starts packaged server with isolated child environment' {
    $global:asepriteLaunchScenario.missingNode=$true
    $nodeDirectory=Join-Path $env:ProgramFiles 'nodejs'; [void][IO.Directory]::CreateDirectory($nodeDirectory)
    Copy-Item -LiteralPath $nativeNode -Destination (Join-Path $nodeDirectory 'node.exe')
    $before=@{}
    foreach ($name in @('CODEX_CLI','ASEPRITE_CHAT_PORT','ASEPRITE_CHAT_READY_FILE','ASEPRITE_CHAT_DISCOVERY_FILE','ASEPRITE_CHAT_IDLE_TIMEOUT_MS')) {
      [Environment]::SetEnvironmentVariable($name, 'preserve-'+$name, 'Process'); $before[$name]='preserve-'+$name
    }
    $result=Bootstrap; $start=$global:asepriteLaunchScenario.starts[-1]
    Assert ($start.file -eq (Join-Path $nodeDirectory 'node.exe')) 'Native Node fallback was not selected'
    Assert ($start.port -eq '0' -and $start.idle -eq '120000') 'Bridge must use OS port assignment and bounded idle lifetime'
    Assert ($start.codex -eq $nativeCodex -and [IO.Path]::IsPathRooted($start.codex)) 'Codex child path must be absolute'
    Assert ($start.window -eq 'Hidden') 'Node window must be hidden'
    Assert ($start.arguments -eq ('"'+(Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/server.mjs')+'"')) 'Packaged server path was not preserved'
    Assert ($start.discovery -eq (Join-Path $env:LOCALAPPDATA 'AsepriteChat/bridge.json')) 'Wrong per-user discovery path'
    foreach ($name in $before.Keys) { Assert ([Environment]::GetEnvironmentVariable($name,'Process') -eq $before[$name]) "Environment leaked: $name" }
  }
  Test 'process creation failure writes a remedy and restores child environment' {
    $global:asepriteLaunchScenario.failStart=$true
    $before=$env:CODEX_CLI
    $result=Bootstrap
    Assert ($result.error -match '重试') 'Process failure must explain retry'
    Assert ($env:CODEX_CLI -eq $before) 'Failed launch leaked child environment'
  }
  Test 'real hidden child publishes readiness reuses idle and avoids busy instance' {
    $global:asepriteLaunchScenario.real=$true
    $fixtureRoot=Join-Path $env:LOCALAPPDATA "extension 中文 ' 100% & `$()"
    $fixtureScripts=Join-Path $fixtureRoot 'scripts'; [void][IO.Directory]::CreateDirectory($fixtureScripts)
    $fixtureBootstrap=Join-Path $fixtureScripts 'launch.ps1'
    Copy-Item -LiteralPath $scriptPath -Destination $fixtureBootstrap
    [IO.File]::WriteAllText((Join-Path $fixtureScripts 'server.mjs'), @'
import http from 'node:http';
import fs from 'node:fs';
let busy = false;
const server = http.createServer((req, res) => {
  if (req.url === '/busy') busy = true;
  res.setHeader('content-type', 'application/json');
  res.end(JSON.stringify({service:'aseprite-chat',protocolVersion:1,pid:process.pid,port:server.address().port,busy}));
});
server.listen(Number(process.env.ASEPRITE_CHAT_PORT), '127.0.0.1', () => {
  const port=server.address().port;
  const data={service:'aseprite-chat',protocolVersion:1,pid:process.pid,port,busy};
  fs.writeFileSync(process.env.ASEPRITE_CHAT_DISCOVERY_FILE,JSON.stringify(data));
  fs.writeFileSync(process.env.ASEPRITE_CHAT_READY_FILE,JSON.stringify({endpoint:`ws://127.0.0.1:${port}`}));
});
setTimeout(() => server.close(), 15000).unref();
'@)
    $first=Bootstrap $fixtureBootstrap
    Assert ($first.endpoint -match '^ws://127\.0\.0\.1:\d+$') 'Native Node child failed readiness'
    Assert ($ownedProcesses.Count -eq 1) 'Fixture did not own exactly one child'
    $second=Bootstrap $fixtureBootstrap
    Assert ($second.endpoint -eq $first.endpoint -and $ownedProcesses.Count -eq 1) 'Idle child was not reused'
    [void](Microsoft.PowerShell.Utility\Invoke-RestMethod -Uri ($first.endpoint.Replace('ws:','http:')+'/busy') -UseBasicParsing)
    $third=Bootstrap $fixtureBootstrap
    Assert ($third.endpoint -ne $first.endpoint -and $ownedProcesses.Count -eq 2) 'Busy child was stolen'
    foreach ($process in $ownedProcesses) { Write-Host "OWNED fixture node.exe pid=$($process.Id)" }
  }
  Write-Host "launch: $passed/$tests tests passed"
} finally {
  foreach ($process in $ownedProcesses) {
    if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $process.Dispose()
  }
  foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name],'Process') }
  $resolvedRoot=[IO.Path]::GetFullPath($testRoot)
  $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($resolvedRoot.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedRoot)) {
    # Windows may briefly retain the executed fixture image after child exit.
    # Retry deletion only inside this suite's uniquely owned temporary root.
    for ($attempt=0; $attempt -lt 20; $attempt++) {
      try { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force; break }
      catch { if ($attempt -eq 19) { throw }; Start-Sleep -Milliseconds 100 }
    }
  }
}
