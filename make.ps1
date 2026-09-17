# Project-local native GNU Make entry point; does not change the system PATH.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$bin = Join-Path $root '.deps/ucrt64/bin'
if (!(Test-Path "$bin/mingw32-make.exe")) { throw 'Run ./tools/bootstrap.ps1 first.' }
$previousPath = $env:PATH
try {
    $env:PATH = "$bin;$env:PATH"
    & "$bin/mingw32-make.exe" -C $root @args
    $code = $LASTEXITCODE
} finally { $env:PATH = $previousPath }
exit $code
