param([string]$Aseprite = 'D:\SteamLibrary\steamapps\common\Aseprite\aseprite.exe')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $projectRoot
try {
  foreach ($suite in @('protocol', 'export', 'executor', 'chat', 'controller', 'launcher', 'timeline', 'account', 'mcp')) {
    $output = & $Aseprite --batch --script "tests/$suite.lua" 2>&1 | Out-String
    Write-Host $output.TrimEnd()
    # Aseprite can report a Lua failure with exit code zero; require the suite's final marker.
    $hasMarker = $output -match "(?m)^${suite}: (\d+)(?:/(\d+))? (?:tests )?passed"
    $allPassed = $hasMarker -and (-not $Matches[2] -or $Matches[1] -eq $Matches[2])
    if ($LASTEXITCODE -ne 0 -or -not $allPassed) {
      throw "$suite suite did not pass"
    }
  }
} finally { Pop-Location }
