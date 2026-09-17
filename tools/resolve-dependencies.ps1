# Maintainer operation: resolve a new lock from the official UCRT64 repository.
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$cache = Join-Path $root '.cache'
New-Item -ItemType Directory -Force $cache | Out-Null
$db = Join-Path $cache 'ucrt64.db'
Invoke-WebRequest -UseBasicParsing 'https://repo.msys2.org/mingw/ucrt64/ucrt64.db' -OutFile $db
$dest = Join-Path $cache ('metadata-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $dest | Out-Null
tar -xf $db -C $dest
if ($LASTEXITCODE) { throw 'Cannot extract package metadata' }
$packages = @{}
foreach ($file in Get-ChildItem $dest -Filter desc -Recurse) {
    $fields = @{}
    $key = $null
    foreach ($line in Get-Content $file.FullName) {
        if ($line -match '^%(.+)%$') { $key = $Matches[1]; $fields[$key] = @() }
        elseif ($line -and $key) { $fields[$key] += $line }
    }
    $packages[$fields.NAME[0]] = $fields
}
$selected = @{}
$providers = @{}
foreach ($p in $packages.Values) {
    foreach ($alias in $p.PROVIDES) { $providers[($alias -replace '[<>=].*$', '')] = $p.NAME[0] }
}
function Select-Package([string]$name) {
    $name = $name -replace '[<>=].*$', ''
    if (!$packages.ContainsKey($name) -and $providers.ContainsKey($name)) { $name = $providers[$name] }
    if ($selected.ContainsKey($name)) { return }
    if (-not $packages.ContainsKey($name)) { throw "Unresolved native dependency: $name" }
    $p = $packages[$name]
    $selected[$name] = $p
    foreach ($dep in $p.DEPENDS) { Select-Package $dep }
}
foreach ($name in 'gcc','make','ninja','htslib','bcftools','samtools') {
    Select-Package ('mingw-w64-ucrt-x86_64-' + $name)
}
$lock = @($selected.Keys | Sort-Object | ForEach-Object {
    $p = $selected[$_]
    [ordered]@{name=$_;version=$p.VERSION[0];url=('https://repo.msys2.org/mingw/ucrt64/' + $p.FILENAME[0]);sha256=$p.SHA256SUM[0];licenses=@($p.LICENSE)}
})
$lock | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $PSScriptRoot 'windows-packages.lock.json') -Encoding utf8
Write-Host "Locked $($lock.Count) native Windows packages."
