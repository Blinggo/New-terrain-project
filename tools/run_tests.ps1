# tools/run_tests.ps1 - M00 / T10 headless test entry point for Windows.
#
# Usage (PowerShell 5.1+):
#   .\tools\run_tests.ps1                     # full headless suite
#   .\tools\run_tests.ps1 -SkipPerf           # skip the generation benchmark
#   .\tools\run_tests.ps1 -ExtraArgs "--with-runtime"
#   $env:GODOT = "C:\bin\Godot_v4.7.2-stable_win64.exe"; .\tools\run_tests.ps1
#
# Exit code: 0 = everything PASSed (BLOCKED allowed), 1 = at least one FAIL, 2 = no Godot binary.
param(
    [switch]$SkipPerf,
    [string[]]$ExtraArgs = @()
)

$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Project = Split-Path -Parent $Here

$candidates = @()
if ($env:GODOT) { $candidates += $env:GODOT }
$candidates += @(
    "$env:LOCALAPPDATA\Programs\Godot\Godot.exe",
    "C:\bin\godot.exe",
    "C:\godot\godot.exe",
    (Get-Command godot -ErrorAction SilentlyContinue).Source,
    (Get-Command godot4 -ErrorAction SilentlyContinue).Source
) | Where-Object { $_ }

$godotBin = $null
foreach ($c in $candidates) {
    if (Test-Path -LiteralPath $c -PathType Leaf) { $godotBin = $c; break }
}
if (-not $godotBin) {
    Write-Error "run_tests.ps1: no Godot binary found. Set `$env:GODOT to a Godot 4.7.x executable."
    exit 2
}

$args = @("--headless", "--path", $Project, "--script", "res://tools/run_tests.gd", "--")
if ($SkipPerf) { $args += "--skip-perf" }
$args += $ExtraArgs

Write-Host "run_tests.ps1: project=$Project godot=$godotBin"
Write-Host "run_tests.ps1: args=$($args -join ' ')"

if (-not (Test-Path -LiteralPath (Join-Path $Project ".godot\extension_list.cfg"))) {
    Write-Host "run_tests.ps1: importing project first (creates .godot/, loads the extension)..."
    & $godotBin --headless --path $Project --import | Out-Null
}

& $godotBin @args
$code = $LASTEXITCODE
Write-Host "run_tests.ps1: exit code $code"
exit $code
