param([string]$PackagePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist/aseprite-chat.aseprite-extension'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($PackagePath)
try {
  # Aseprite v1.3.18 selects the first entry named package.json, including nested
  # dependency manifests, and uses its directory as the extraction prefix.
  $firstManifest = $archive.Entries | Where-Object { ($_.FullName -split '/')[-1] -eq 'package.json' } | Select-Object -First 1
  if (-not $firstManifest) { throw 'No installable extension manifest' }
  $reader = [IO.StreamReader]::new($firstManifest.Open())
  try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
  if ($firstManifest.FullName -ne 'package.json' -or $manifest.name -ne 'aseprite-chat') {
    throw "Aseprite would install '$($manifest.name)' from '$($firstManifest.FullName)' instead of Aseprite Chat"
  }
  foreach ($file in @('main.lua','launcher.lua','timeline.lua','scripts/launch.ps1','scripts/server.mjs','node_modules/ws/package.json','node_modules/ws/wrapper.mjs','node_modules/ws/LICENSE')) {
    if (-not $archive.GetEntry($file)) { throw "Missing installed runtime: $file" }
  }
  $keys = @($manifest.contributes.keys)
  if ($keys.Count -ne 1) { throw 'Missing extension keyboard contribution' }
  $keyEntry = $archive.GetEntry(($keys[0].path -replace '^\./', ''))
  if (-not $keyEntry) { throw 'Missing packaged keyboard bindings' }
  $keyReader = [IO.StreamReader]::new($keyEntry.Open())
  try { [xml]$keyXml = $keyReader.ReadToEnd() } finally { $keyReader.Dispose() }
  foreach ($context in @('Normal', 'Selection', 'FramesSelection')) {
    $enter = $keyXml.SelectSingleNode("/keyboard/commands/key[@command='AsepriteChatEnter'][@context='$context']")
    if (-not $enter -or $enter.shortcut -ne 'Enter') { throw "Missing Enter binding for $context" }
  }
  if ($keyXml.SelectSingleNode('/keyboard/commands/key[@context="Transformation"]')) {
    throw 'Chat must preserve the native transformation Enter binding'
  }
  Write-Output "PASS Aseprite installer selects aseprite-chat $($manifest.version) at archive root; runtime remains inside this extension"
} finally { $archive.Dispose() }
