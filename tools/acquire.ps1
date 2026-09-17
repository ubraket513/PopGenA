[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Manifest,
    [Parameter(Mandatory=$true)][string]$Out,
    [Parameter(Mandatory=$true)][long]$MaxBytes,
    [switch]$Download
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Get-Md5([string]$Path) {
    $stream=[IO.File]::OpenRead($Path); $hash=[Security.Cryptography.MD5]::Create()
    try { ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
    finally { $stream.Dispose(); $hash.Dispose() }
}
function Assert-NoReparse([string]$Path) {
    $cursor=$Path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse paths are not accepted: $cursor" }
        }
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
}
$data = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
if ($data.schema_version -ne 1 -or $data.status -cne 'ready') { throw 'Manifest must have schema_version 1 and status ready' }
if ($data.study -cnotmatch '^(PRJ[EDN][AB][0-9]+|[EDS]RP[0-9]+)$') { throw 'Invalid manifest study' }
if ([string]::IsNullOrWhiteSpace($data.reference.assembly) -or $data.reference.fasta_sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Missing explicit reference identity' }
$files=@($data.files)
if ($files.Count -eq 0 -or $MaxBytes -le 0) { throw 'Nonempty files and positive MaxBytes are required' }
$root=[IO.Path]::GetFullPath($Out)
Assert-NoReparse $root
if ((Test-Path -LiteralPath $root) -and -not (Test-Path -LiteralPath $root -PathType Container)) { throw 'Output is not a directory' }
$names=@{}; $runIdentity=@{}; $individuals=@{}; $sampleIds=@{}; $total=0L; $missing=0L; $plan=@()
foreach ($file in $files) {
    if ($file.run -cnotmatch '^[EDS]RR[0-9]+$' -or $file.mate -notin @(1,2)) { throw 'Invalid run/mate' }
    $expected=$file.run+'_'+$file.mate+'.fastq.gz'
    if ($file.name -cne $expected -or $names.ContainsKey($file.name)) { throw 'Unsafe, duplicate, or unexpected output name' }
    $names[$file.name]=$true
    if ($file.sample_accession -cnotmatch '^(SAM[END][A-Z]?[0-9]+|[EDS]RS[0-9]+)$' -or $file.individual -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') { throw 'Invalid explicit sample mapping' }
    $identity=$file.sample_accession+'|'+$file.individual
    if ($runIdentity.ContainsKey($file.run) -and $runIdentity[$file.run] -cne $identity) { throw 'Inconsistent run sample mapping' }
    $runIdentity[$file.run]=$identity
    if ($sampleIds.ContainsKey($file.sample_accession) -and $sampleIds[$file.sample_accession] -cne $file.individual) { throw 'Inconsistent sample identity' }
    if ($individuals.ContainsKey($file.individual) -and $individuals[$file.individual] -cne $file.sample_accession) { throw 'Ambiguous individual mapping' }
    $sampleIds[$file.sample_accession]=$file.individual; $individuals[$file.individual]=$file.sample_accession
    $uri=$null; $size=0L
    if (-not [uri]::TryCreate($file.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.Host -ne 'ftp.sra.ebi.ac.uk' -or -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -cnotmatch ('^/vol1/fastq/[A-Za-z0-9/]+/'+[regex]::Escape($expected)+'$')) { throw 'Only canonical HTTPS ftp.sra.ebi.ac.uk FASTQ URLs are accepted' }
    if ($file.md5 -notmatch '^[a-fA-F0-9]{32}$' -or -not [long]::TryParse([string]$file.bytes,[ref]$size) -or $size -le 0) { throw 'Invalid checksum or byte size' }
    if ($size -gt ($MaxBytes-$total)) { throw 'Manifest total exceeds MaxBytes (includes existing files)' }
    $total += $size
    $path=Join-Path $root $expected; Assert-NoReparse $path
    $state='pending'
    if (Test-Path -LiteralPath $path) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -ne $size -or (Get-Md5 $path) -ne $file.md5.ToLowerInvariant()) { throw "Existing file is corrupt; preserved without overwrite: $path" }
        $state='reuse'
    } else { $missing += $size }
    $plan += [ordered]@{name=$expected;bytes=$size;state=$state;url=$file.url;md5=$file.md5.ToLowerInvariant()}
}
foreach ($runId in $runIdentity.Keys) {
    if (-not $names.ContainsKey($runId+'_1.fastq.gz') -or -not $names.ContainsKey($runId+'_2.fastq.gz')) { throw "Missing paired file: $runId" }
}
$drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($root))
$reserve=64MB
if ($missing -gt ($drive.AvailableFreeSpace-$reserve)) { throw 'Insufficient free space for missing files plus 64 MiB reserve' }
$summary=[ordered]@{schema_version=1;mode=$(if($Download){'download'}else{'plan'});total_bytes=$total;download_bytes=$missing;max_bytes=$MaxBytes;reference=$data.reference;files=$plan}
if (-not $Download) { $summary|ConvertTo-Json -Depth 10; return }
New-Item -ItemType Directory -Force -Path $root | Out-Null
Assert-NoReparse $root
$lock=$null
try {
    $lock=New-Object IO.FileStream((Join-Path $root '.acquire.lock'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,1,[IO.FileOptions]::DeleteOnClose)
    foreach ($item in $plan) {
        if ($item.state -eq 'reuse') { continue }
        $final=Join-Path $root $item.name
        if (Test-Path -LiteralPath $final) { throw "Output appeared after planning: $final" }
        $part=Join-Path $root ($item.name+'.'+[guid]::NewGuid().ToString('N')+'.part')
        $response=$null; $inputStream=$null; $outputStream=$null; $hash=$null
        try {
            $request=[Net.HttpWebRequest]::Create($item.url)
            $request.AllowAutoRedirect=$false; $request.Timeout=120000; $request.ReadWriteTimeout=120000
            $response=$request.GetResponse()
            if ([int]$response.StatusCode -ne 200) { throw 'Download requires HTTP 200; redirects are not followed' }
            if ($response.ContentLength -ge 0 -and $response.ContentLength -ne $item.bytes) { throw 'Server Content-Length does not match manifest' }
            $inputStream=$response.GetResponseStream()
            $outputStream=New-Object IO.FileStream($part,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $hash=[Security.Cryptography.MD5]::Create(); $buffer=New-Object byte[] (1MB); $received=0L
            while (($count=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                if ($count -gt ($item.bytes-$received)) { throw 'Downloaded bytes exceed manifest size' }
                $outputStream.Write($buffer,0,$count); $null=$hash.TransformBlock($buffer,0,$count,$null,0); $received += $count
            }
            $null=$hash.TransformFinalBlock([byte[]]@(),0,0)
            $digest=([BitConverter]::ToString($hash.Hash)).Replace('-','').ToLowerInvariant()
            if ($received -ne $item.bytes -or $digest -ne $item.md5) { throw 'Downloaded size or MD5 mismatch; final file not published' }
            $outputStream.Flush($true); $outputStream.Dispose(); $outputStream=$null
            Assert-NoReparse $root
            [IO.File]::Move($part,$final)
            $item.state='downloaded'
        } finally {
            if ($outputStream) { $outputStream.Dispose() }; if ($inputStream) { $inputStream.Dispose() }
            if ($response) { $response.Dispose() }; if ($hash) { $hash.Dispose() }
            if (Test-Path -LiteralPath $part) { [IO.File]::Delete($part) }
        }
    }
} finally { if ($lock) { $lock.Dispose() } }
$summary|ConvertTo-Json -Depth 10
