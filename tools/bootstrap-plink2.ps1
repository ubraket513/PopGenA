[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$lock = Get-Content (Join-Path $PSScriptRoot 'plink2.lock.json') -Raw | ConvertFrom-Json
function Get-Sha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
    finally { $stream.Dispose(); $hash.Dispose() }
}
$cache = Join-Path $root '.cache'
$install = Join-Path $root '.deps/plink2'
$exe = Join-Path $root $lock.executable
New-Item -ItemType Directory -Force $cache,$install | Out-Null
$archive = Join-Path $cache ([uri]$lock.url).Segments[-1]
if (-not (Test-Path -LiteralPath $archive)) {
    Write-Host "Downloading pinned PLINK2 $($lock.version)"
    Invoke-WebRequest -UseBasicParsing $lock.url -OutFile ($archive + '.part')
    Move-Item -LiteralPath ($archive + '.part') -Destination $archive
}
if ((Get-Sha256 $archive) -ne $lock.sha256) { throw "PLINK2 archive SHA256 mismatch: $archive" }
if (-not (Test-Path -LiteralPath $exe) -or (Get-Sha256 $exe) -ne $lock.executable_sha256) {
    # Extract only the pinned application; the bundled vcf_subset utility is unused.
    & tar -xf $archive -C $install plink2.exe
    if ($LASTEXITCODE) { throw 'PLINK2 archive extraction failed' }
}
if ((Get-Sha256 $exe) -ne $lock.executable_sha256) { throw "PLINK2 executable SHA256 mismatch: $exe" }
$version = ((& $exe --version) -join "`n").Trim()
if ($LASTEXITCODE -ne 0 -or $version -ne $lock.version_output) { throw "Unexpected PLINK2 version: $version" }
Write-Host "$version ready at $exe"
