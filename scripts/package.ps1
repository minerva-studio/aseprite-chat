param([string]$OutputPath)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$runtimeFiles = @('package.json', 'package-lock.json', 'main.lua', 'chat.lua', 'chat.aseprite-keys', 'codex.lua', 'executor.lua', 'launcher.lua', 'timeline.lua', 'account.lua', 'scripts/server.mjs', 'scripts/launch.ps1', 'README.md', 'docs/validation.md')
foreach ($file in $runtimeFiles) {
  if (-not (Test-Path -LiteralPath (Join-Path $projectRoot $file) -PathType Leaf)) { throw "Missing runtime file: $file" }
}
$wsRoot = Join-Path $projectRoot 'node_modules/ws'
$wsPackagePath = Join-Path $wsRoot 'package.json'
if (-not (Test-Path -LiteralPath $wsPackagePath -PathType Leaf)) { throw 'Missing installed ws runtime: node_modules/ws/package.json' }
$wsPackage = Get-Content -LiteralPath $wsPackagePath -Raw | ConvertFrom-Json
if ($wsPackage.version -ne '8.22.0') { throw "Expected ws 8.22.0, found $($wsPackage.version)" }
if (-not (Test-Path -LiteralPath (Join-Path $wsRoot 'LICENSE') -PathType Leaf)) { throw 'Missing ws license' }
$wsFiles = @(Get-ChildItem -LiteralPath $wsRoot -File -Recurse | ForEach-Object {
  $relative = $_.FullName.Substring($projectRoot.Length).TrimStart([char[]]@(92, 47)).Replace([char]92, '/')
  if ($relative -notmatch '^node_modules/ws/(node_modules|prebuilds)/' -and $relative -notmatch '\.(node|dll|so|dylib)$') { $relative }
})
# Aseprite selects the first package.json anywhere in the archive. Its own
# manifest must precede dependency manifests so installation targets this root.
$packageEntries = @('package.json') + @($runtimeFiles + $wsFiles | Where-Object { $_ -ne 'package.json' } | Sort-Object -Unique)
Add-Type -AssemblyName System.IO.Compression
$outputPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  Join-Path (Join-Path $projectRoot 'dist') 'aseprite-chat.aseprite-extension'
} else {
  [System.IO.Path]::GetFullPath($OutputPath)
}
$outputDirectory = Split-Path -Parent $outputPath
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$stream = [System.IO.File]::Open($outputPath, [System.IO.FileMode]::Create)
$archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
try {
  foreach ($file in $packageEntries) {
    $entry = $archive.CreateEntry($file, [System.IO.Compression.CompressionLevel]::Optimal)
    $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
    $entryStream = $entry.Open()
    $inputStream = [System.IO.File]::OpenRead((Join-Path $projectRoot $file))
    try { $inputStream.CopyTo($entryStream) } finally { $inputStream.Dispose(); $entryStream.Dispose() }
  }
} finally { $archive.Dispose(); $stream.Dispose() }
Get-Item -LiteralPath $outputPath | Select-Object FullName,Length
