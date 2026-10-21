$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$runtimeFiles = @('package.json', 'package-lock.json', 'main.lua', 'chat.lua', 'codex.lua', 'executor.lua', 'scripts/server.mjs', 'README.md', 'docs/validation.md')
foreach ($file in $runtimeFiles) {
  if (-not (Test-Path -LiteralPath (Join-Path $projectRoot $file) -PathType Leaf)) { throw "Missing runtime file: $file" }
}
Add-Type -AssemblyName System.IO.Compression
$outputDirectory = Join-Path $projectRoot 'dist'
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$outputPath = Join-Path $outputDirectory 'aseprite-chat.aseprite-extension'
$stream = [System.IO.File]::Open($outputPath, [System.IO.FileMode]::Create)
$archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
try {
  foreach ($file in ($runtimeFiles | Sort-Object)) {
    $entry = $archive.CreateEntry($file, [System.IO.Compression.CompressionLevel]::Optimal)
    $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
    $entryStream = $entry.Open()
    $inputStream = [System.IO.File]::OpenRead((Join-Path $projectRoot $file))
    try { $inputStream.CopyTo($entryStream) } finally { $inputStream.Dispose(); $entryStream.Dispose() }
  }
} finally { $archive.Dispose(); $stream.Dispose() }
Get-Item -LiteralPath $outputPath | Select-Object FullName,Length
