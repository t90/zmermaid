$ErrorActionPreference = 'Stop'
$zig = (Get-Command zig.exe -ErrorAction SilentlyContinue).Source
if (-not $zig) { throw 'Zig 0.16.0 must be available on PATH.' }
$env:ZIG_GLOBAL_CACHE_DIR = Join-Path $PSScriptRoot '.zig-global-cache'
$env:ZIG_LOCAL_CACHE_DIR = Join-Path $PSScriptRoot '.zig-cache'
Push-Location $PSScriptRoot
try {
    & $zig build -Doptimize=ReleaseSmall --summary all
    if ($LASTEXITCODE -ne 0) { throw 'Build or tests failed' }
    Get-Item zig-out\zmermaid.wasm | Select-Object Name,Length
} finally { Pop-Location }
