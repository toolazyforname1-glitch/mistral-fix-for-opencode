param(
  [string]$PluginSource = (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugin\vibe-mode')
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$final = Join-Path $root 'final'
$build = Join-Path $root 'build'
$payloadDir = Join-Path $final 'payload'
$pluginDst = Join-Path $payloadDir 'vibe-mode'

Write-Host '== staging payload' -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $pluginDst, $build | Out-Null
if (-not (Test-Path (Join-Path $PluginSource 'index.js'))) {
  throw "Plugin source not found: $PluginSource"
}
Copy-Item (Join-Path $PluginSource '*') $pluginDst -Recurse -Force
foreach ($name in @('index.js', 'bridge.mjs', 'tui.tsx', 'package.json')) {
  if (-not (Test-Path (Join-Path $pluginDst $name))) { throw "payload missing $name" }
}

Write-Host '== packing payload.zip' -ForegroundColor Cyan
$zip = Join-Path $build 'payload.zip'
Remove-Item $zip -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $final 'payload'), (Join-Path $final 'install.ps1') -DestinationPath $zip -CompressionLevel Optimal
Write-Host ("   payload.zip " + [math]::Round((Get-Item $zip).Length / 1KB, 1) + " KB")

Write-Host '== compiling launcher' -ForegroundColor Cyan
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'csc.exe not found' }

$exe = Join-Path $final 'VibeModeSetup.exe'
Remove-Item $exe -Force -ErrorAction SilentlyContinue
$outArg = '/out:' + $exe
$resArg = '/resource:' + $zip + ',payload.zip'
& $csc /nologo /target:exe $outArg $resArg /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll (Join-Path $final 'src\Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw "csc failed with $LASTEXITCODE" }

$size = (Get-Item $exe).Length
Write-Host ("== built " + $exe + " (" + [math]::Round($size / 1KB, 1) + " KB)") -ForegroundColor Green
