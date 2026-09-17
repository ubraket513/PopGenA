# Internal bounded region acquisition used by prepare-real-cohort.ps1.
# $root, $Out, $lock, Digest and Utf8 come from the caller.
$source=$lock.files | Where-Object name -eq 'chr21.vcf.gz'
$index=$lock.files | Where-Object name -eq 'chr21.vcf.gz.tbi'
$metadata=$lock.metadata[0]
foreach($r in @($index,$metadata)){
    $path=Join-Path $Out $r.name
    if(!(Test-Path -LiteralPath $path)){
        & curl.exe --fail --silent --show-error --proto '=https' --max-time 60 --max-filesize $r.bytes --output ($path+'.part') $r.url
        if($LASTEXITCODE -or (Get-Item -LiteralPath ($path+'.part')).Length -ne $r.bytes){throw "Metadata download failed: $($r.name)"}
        Move-Item -LiteralPath ($path+'.part') -Destination $path
    }
    if($r.PSObject.Properties['md5'] -and (Digest $path 'MD5') -ne $r.md5){throw 'Index MD5 differs from release manifest'}
    if($r.PSObject.Properties['sha256'] -and (Digest $path 'SHA256') -ne $r.sha256){throw 'Original panel hash differs'}
}
$ranges=& (Join-Path $root 'build/region-ranges.exe') (Join-Path $Out $index.name) 'chr21:15000000-16000000'
if($LASTEXITCODE){throw 'Cannot plan indexed ranges; build region-ranges.exe first'}
$ranges=@($ranges | ConvertFrom-Json)
$ranges=@(@{start=0L;end=524287L})+$ranges+@(@{start=($source.bytes-28);end=($source.bytes-1)})
$requests=@();$total=0L;$cache=Join-Path $Out 'region-chunks';New-Item -ItemType Directory -Force $cache | Out-Null
foreach($range in $ranges){
    if($range.start -lt 0 -or $range.end -ge $source.bytes -or $range.end -lt $range.start){throw 'Invalid indexed byte range'}
    for($start=[long]$range.start;$start -le $range.end;$start+=1048576){
        $end=[Math]::Min($start+1048575,$range.end);$size=$end-$start+1;$total+=$size
        $requests+=@{start=$start;end=$end;bytes=$size;path=(Join-Path $cache "$start-$end.bgzf")}
    }
}
if($total -gt 32000000){throw 'Indexed genotype selection exceeds 32 MB byte budget'}
$plan=@{source=$source.url;source_bytes=$source.bytes;source_full_md5_not_verified=$source.md5;region='chr21:15000000-16000000';range_bytes=$total;reference_bytes=12709705;requests=$requests;scope='Partial byte cache, not a complete source VCF'}
Utf8 (Join-Path $Out 'region-plan.json') (($plan | ConvertTo-Json -Depth 8)+"`n")
$argsList=@('--parallel','--parallel-max','4');$count=0
foreach($r in $requests){
    if((Test-Path -LiteralPath $r.path) -and (Get-Item -LiteralPath $r.path).Length -eq $r.bytes -and (Test-Path -LiteralPath ($r.path+'.sha256')) -and (Digest $r.path 'SHA256') -eq ([IO.File]::ReadAllText($r.path+'.sha256').Trim())){continue}
    if($count++){$argsList+='--next'}
    $argsList+=@('--fail','--silent','--show-error','--proto','=https','--connect-timeout','30','--max-time','180','--max-filesize',[string]$r.bytes,'--range',"$($r.start)-$($r.end)",'--dump-header',($r.path+'.headers'),'--output',($r.path+'.part'),$source.url)
}
if($count){& curl.exe @argsList;if($LASTEXITCODE){throw 'A bounded region transfer failed; complete cached ranges can be reused'}}
foreach($r in $requests){
    $part=$r.path+'.part'
    if(Test-Path -LiteralPath $part){
        $headers=[IO.File]::ReadAllText($r.path+'.headers')
        if((Get-Item -LiteralPath $part).Length -ne $r.bytes -or $headers -notmatch "(?im)^Content-Range: bytes $($r.start)-$($r.end)/$($source.bytes)\s*$"){throw 'Server did not return the exact requested range'}
        Move-Item -LiteralPath $part -Destination $r.path -Force
        Utf8 ($r.path+'.sha256') (Digest $r.path 'SHA256')
    }
    if(!(Test-Path -LiteralPath $r.path) -or (Digest $r.path 'SHA256') -ne ([IO.File]::ReadAllText($r.path+'.sha256').Trim())){throw 'Region cache integrity failure'}
}
$vcf=Join-Path $Out 'chr21.region-cache.vcf.gz'
$output=[IO.File]::Create($vcf)
try{
    $output.SetLength($source.bytes)
    foreach($r in $requests){[void]$output.Seek($r.start,[IO.SeekOrigin]::Begin);$input=[IO.File]::OpenRead($r.path);try{$input.CopyTo($output)}finally{$input.Dispose()}}
}finally{$output.Dispose()}
Copy-Item -LiteralPath (Join-Path $Out $index.name) -Destination ($vcf+'.tbi') -Force
$compressed=Join-Path $Out 'chr21.fa.gz'
if(!(Test-Path -LiteralPath $compressed)){
    & curl.exe --fail --silent --show-error --proto '=https' --max-time 180 --max-filesize 12709705 --output ($compressed+'.part') 'https://hgdownload.soe.ucsc.edu/goldenPath/hg38/chromosomes/chr21.fa.gz'
    if($LASTEXITCODE){throw 'Reference download failed'}
    Move-Item -LiteralPath ($compressed+'.part') -Destination $compressed
}
$fasta=Join-Path $Out 'chr21.fa'
if((Digest $compressed 'MD5') -ne '184df2bd9b812b6e6b6da16c6021369e'){throw 'UCSC chromosome archive MD5 mismatch'}
$stream=[IO.File]::OpenRead($compressed);$gz=New-Object IO.Compression.GZipStream($stream,[IO.Compression.CompressionMode]::Decompress);$reader=New-Object IO.StreamReader($gz)
try{$contents=$reader.ReadToEnd()}finally{$reader.Dispose();$gz.Dispose();$stream.Dispose()}
if(!$contents.StartsWith(">chr21`n")){throw 'Unexpected chromosome reference header'}
$sequence=$contents.Substring($contents.IndexOf("`n")+1).Replace("`r",'').Replace("`n",'').ToUpperInvariant()
$reference=$lock.files | Where-Object name -eq 'chr21.sequence.txt'
if($sequence.Length -ne $reference.bases){throw 'Reference chromosome length mismatch'}
$md5=[Security.Cryptography.MD5]::Create()
try{$actual=([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::ASCII.GetBytes($sequence)))).Replace('-','').ToLowerInvariant()}finally{$md5.Dispose()}
if($actual -ne $reference.sequence_md5){throw 'UCSC chromosome sequence differs from original GRCh38 reference dictionary'}
Utf8 $fasta $contents
$plan.reference_sequence_md5=$actual
$plan.reference_compressed_sha256=Digest $compressed 'SHA256'
$plan.downloaded_range_sha256=@($requests | ForEach-Object {@{start=$_.start;end=$_.end;sha256=(Digest $_.path 'SHA256')}})
Utf8 (Join-Path $Out 'region-provenance.json') (($plan | ConvertTo-Json -Depth 10)+"`n")
