[CmdletBinding()] param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$lock=Get-Content (Join-Path $PSScriptRoot 'raw-tools.lock.json') -Raw|ConvertFrom-Json
function Hash([string]$Path){$s=[IO.File]::OpenRead($Path);$h=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($h.ComputeHash($s))).Replace('-','').ToLowerInvariant()}finally{$s.Dispose();$h.Dispose()}}
$cache=Join-Path $root '.cache';$install=Join-Path $root '.deps/raw-tools'
New-Item -ItemType Directory -Force $cache,$install|Out-Null
foreach($package in $lock.packages){
    $archive=Join-Path $cache ([uri]$package.url).Segments[-1]
    if(!(Test-Path -LiteralPath $archive)){
        Write-Host "Downloading $($package.name) $($package.version): $($package.origin)"
        Invoke-WebRequest -UseBasicParsing $package.url -OutFile ($archive+'.part')
        Move-Item -LiteralPath ($archive+'.part') -Destination $archive
    }
    if((Hash $archive) -ne $package.sha256){throw "Archive checksum mismatch: $archive"}
    foreach($file in $package.files){
        $path=Join-Path $install $file.path
        if(!(Test-Path -LiteralPath $path) -or (Hash $path) -ne $file.sha256){
            & tar -xf $archive -C $install $file.path
            if($LASTEXITCODE){throw "Cannot extract $($file.path)"}
        }
        if((Hash $path) -ne $file.sha256){throw "Installed checksum mismatch: $path"}
    }
}
Write-Host 'Pinned native fastp and Bowtie2 ready. No sequencing data downloaded.'
