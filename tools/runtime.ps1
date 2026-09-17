$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dest = Join-Path $root 'build'
New-Item -ItemType Directory -Force $dest | Out-Null
Get-ChildItem (Join-Path $root '.deps/ucrt64/bin') -Filter '*.dll' | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
}
Set-Content (Join-Path $dest 'runtime.stamp') 'Native UCRT64 runtime copied' -Encoding ascii
