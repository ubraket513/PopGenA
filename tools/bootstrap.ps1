[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
function Get-FileHash([string]$LiteralPath,[string]$Algorithm) {
    $stream=[IO.File]::OpenRead($LiteralPath);$hash=[Security.Cryptography.SHA256]::Create()
    try { @{Hash=([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-','')} }
    finally { $stream.Dispose();$hash.Dispose() }
}
$root = Split-Path $PSScriptRoot -Parent
foreach ($header in (Get-Content (Join-Path $PSScriptRoot 'headers.lock.json') -Raw | ConvertFrom-Json)) {
    if ((Get-FileHash -LiteralPath (Join-Path $root $header.path) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $header.sha256) {
        throw "Vendored header hash mismatch: $($header.path)"
    }
}
$cache = Join-Path $root '.cache'
$deps = Join-Path $root '.deps'
New-Item -ItemType Directory -Force $cache,$deps | Out-Null
$lock = Get-Content (Join-Path $PSScriptRoot 'windows-packages.lock.json') -Raw | ConvertFrom-Json
foreach ($p in $lock) {
    $archive = Join-Path $cache ([uri]$p.url).Segments[-1]
    if (-not (Test-Path -LiteralPath $archive)) {
        Write-Host "Downloading $($p.name) $($p.version)"
        Invoke-WebRequest -UseBasicParsing $p.url -OutFile ($archive + '.part')
        Move-Item -LiteralPath ($archive + '.part') -Destination $archive
    }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $p.sha256) {
        throw "SHA256 mismatch: $archive"
    }
    $stamp = Join-Path $deps ($p.name + '.sha256')
    if (!(Test-Path $stamp) -or (Get-Content $stamp -Raw).Trim() -ne $p.sha256) {
        Write-Host "Extracting $($p.name)"
        tar -xf $archive -C $deps
        if ($LASTEXITCODE) { throw "Extraction failed: $archive" }
        Set-Content $stamp $p.sha256 -Encoding ascii
    }
}
& (Join-Path $PSScriptRoot 'bootstrap-plink2.ps1')
& (Join-Path $PSScriptRoot 'bootstrap-raw.ps1')
Write-Host 'Native Windows dependencies ready. Run .\make.ps1 check'
