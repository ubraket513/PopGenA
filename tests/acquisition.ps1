$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
$testRoot=Join-Path $project ('build/acquisition-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $testRoot | Out-Null
$utf8=New-Object Text.UTF8Encoding($false)
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }
function Write-Text([string]$path,[string]$text) { [IO.File]::WriteAllText($path,$text,$utf8) }
function Save($value,[string]$path) { Write-Text $path ($value|ConvertTo-Json -Depth 20) }
function Fails([scriptblock]$operation,[string]$message) {
    $failed=$false
    try { & $operation | Out-Null } catch { $failed=$true }
    Assert $failed $message
}
$discover=Join-Path $project 'tools/discover-ena.ps1'; $acquire=Join-Path $project 'tools/acquire.ps1'
$report=Join-Path $testRoot 'report.tsv'; $mapping=Join-Path $testRoot 'mapping.tsv'
$header="run_accession`tsample_accession`tsecondary_sample_accession`tstudy_accession`tlibrary_layout`tfastq_ftp`tfastq_md5`tfastq_bytes`n"
$row="ERR1234567`tSAMN123456`tSRS123456`tPRJEB31736`tPAIRED`tftp.sra.ebi.ac.uk/vol1/fastq/ERR123/007/ERR1234567/ERR1234567_1.fastq.gz;ftp.sra.ebi.ac.uk/vol1/fastq/ERR123/007/ERR1234567/ERR1234567_2.fastq.gz`t900150983cd24fb0d6963f7d28e17f72;900150983cd24fb0d6963f7d28e17f72`t3;3`n"
Write-Text $report ($header+$row)
Write-Text $mapping "sample_accession`tindividual`nSAMN123456`tperson1`n"
$referenceHash='a'*64
& $discover -Out "$testRoot/metadata" -ReportPath $report
Assert (-not (Test-Path "$testRoot/metadata/manifest.json")) 'Metadata discovery created executable manifest'
& $discover -Out "$testRoot/ready" -ReportPath $report -Mapping $mapping -ReferenceAssembly 'synthetic-reference' -ReferenceSha256 $referenceHash
$manifest="$testRoot/ready/manifest.json"
$data=Get-Content $manifest -Raw|ConvertFrom-Json
Assert ($data.files.Count -eq 2 -and $data.files[0].individual -eq 'person1') 'Discovery lost pairing or mapping'
$plan=(& $acquire -Manifest $manifest -Out "$testRoot/data" -MaxBytes 6)|ConvertFrom-Json
Assert ($plan.mode -eq 'plan' -and $plan.download_bytes -eq 6 -and -not (Test-Path "$testRoot/data")) 'Default plan created output or incorrect budget'
Fails { & $acquire -Manifest $manifest -Out "$testRoot/data" -MaxBytes 5 } 'Size budget not enforced'
New-Item -ItemType Directory "$testRoot/data"|Out-Null
foreach ($file in $data.files) { Write-Text (Join-Path "$testRoot/data" $file.name) 'abc' }
$resume=(& $acquire -Manifest $manifest -Out "$testRoot/data" -MaxBytes 6 -Download)|ConvertFrom-Json
Assert ($resume.download_bytes -eq 0 -and @($resume.files|Where-Object state -ne 'reuse').Count -eq 0) 'Valid existing files not reused'
Assert (-not (Test-Path "$testRoot/data/.acquire.lock")) 'Acquisition lock leaked'
Write-Text "$testRoot/data/ERR1234567_1.fastq.gz" 'bad'
Fails { & $acquire -Manifest $manifest -Out "$testRoot/data" -MaxBytes 6 -Download } 'Corrupt existing file accepted'
Assert ([IO.File]::ReadAllText("$testRoot/data/ERR1234567_1.fastq.gz") -eq 'bad') 'Corrupt existing file overwritten'
foreach ($mutation in @('md5','url','mapping','name','mate','reference','bytes')) {
    $copy=Get-Content $manifest -Raw|ConvertFrom-Json
    switch ($mutation) {
        md5 { $copy.files[0].md5='broken' }
        url { $copy.files[0].url='https://evil.example/ERR1234567_1.fastq.gz' }
        mapping { $copy.files[1].individual='someone-else' }
        name { $copy.files[0].name='../escape.fastq.gz' }
        mate { $copy.files=@($copy.files[0]) }
        reference { $copy.reference.fasta_sha256='broken' }
        bytes { $copy.files[0].bytes=0 }
    }
    Save $copy "$testRoot/bad.json"
    Fails { & $acquire -Manifest "$testRoot/bad.json" -Out "$testRoot/invalid" -MaxBytes 6 -Download } "Invalid $mutation accepted"
    Assert (-not (Test-Path "$testRoot/invalid")) 'Invalid manifest caused partial publication'
}
Write-Text $mapping "sample_accession`tindividual`nSAMN123456`tperson1`nSAMN123456`tperson2`n"
Fails { & $discover -Out "$testRoot/duplicate" -ReportPath $report -Mapping $mapping -ReferenceAssembly synthetic -ReferenceSha256 $referenceHash } 'Ambiguous mapping accepted'
Assert (-not (Test-Path "$testRoot/duplicate/manifest.json")) 'Ambiguous mapping published manifest'
Write-Text $mapping "sample_accession`tindividual`nSAMN999`tperson1`n"
Fails { & $discover -Out "$testRoot/unmapped" -ReportPath $report -Mapping $mapping -ReferenceAssembly synthetic -ReferenceSha256 $referenceHash } 'Missing mapping accepted'
Write-Text $report ($header+$row.Replace('PAIRED','SINGLE'))
Fails { & $discover -Out "$testRoot/single" -ReportPath $report -Mapping $mapping -ReferenceAssembly synthetic -ReferenceSha256 $referenceHash } 'Single-end row accepted'
Assert (Test-Path "$testRoot/single/catalog.json") 'Rejected discovery metadata not retained'
Write-Text $report ($header+$row.Replace('3;3','3;3;3'))
Fails { & $discover -Out "$testRoot/extra-file" -ReportPath $report -Mapping $mapping -ReferenceAssembly synthetic -ReferenceSha256 $referenceHash } 'Ambiguous file cardinality accepted'
Write-Text $report ($header+$row.Replace('900150983cd24fb0d6963f7d28e17f72','invalid'))
Fails { & $discover -Out "$testRoot/report-checksum" -ReportPath $report -Mapping $mapping -ReferenceAssembly synthetic -ReferenceSha256 $referenceHash } 'Invalid discovery checksum accepted'
Write-Text "$testRoot/data/ERR1234567_1.fastq.gz" 'abc'
# Orphan .part files have no completion meaning and cannot replace final files.
Write-Text "$testRoot/data/ERR1234567_1.fastq.gz.stale.part" 'bad'
$resume=(& $acquire -Manifest $manifest -Out "$testRoot/data" -MaxBytes 6 -Download)|ConvertFrom-Json
Assert ($resume.download_bytes -eq 0) 'Orphan partial interfered with verified reuse'
# Register a process-local in-memory WebRequest transport for this synthetic run
# only. This exercises the production streaming and publication code offline.
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Text;
public class AcquisitionTestFactory : IWebRequestCreate {
    public static string Body = "bad";
    public static HttpStatusCode Status = HttpStatusCode.OK;
    public WebRequest Create(Uri uri) { return new AcquisitionTestRequest(); }
}
public class AcquisitionTestRequest : WebRequest {
    public bool AllowAutoRedirect { get; set; }
    public int ReadWriteTimeout { get; set; }
    public override int Timeout { get; set; }
    public override WebResponse GetResponse() { return new AcquisitionTestResponse(); }
}
public class AcquisitionTestResponse : WebResponse {
    public HttpStatusCode StatusCode { get { return AcquisitionTestFactory.Status; } }
    public override long ContentLength { get { return -1; } set {} }
    public override Stream GetResponseStream() {
        return new MemoryStream(Encoding.ASCII.GetBytes(AcquisitionTestFactory.Body));
    }
}
'@
$registered=[Net.WebRequest]::RegisterPrefix('https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR123/007/ERR1234567/',(New-Object AcquisitionTestFactory))
Assert $registered 'Offline test transport registration failed'
[AcquisitionTestFactory]::Status=[Net.HttpStatusCode]::Redirect
Fails { & $acquire -Manifest $manifest -Out "$testRoot/redirect" -MaxBytes 6 -Download } 'Redirect accepted'
Assert (@(Get-ChildItem -LiteralPath "$testRoot/redirect" -Force).Count -eq 0) 'Redirect published files'
[AcquisitionTestFactory]::Status=[Net.HttpStatusCode]::OK
foreach ($body in @('bad','ab','abcd')) {
    [AcquisitionTestFactory]::Body=$body
    Fails { & $acquire -Manifest $manifest -Out "$testRoot/streamed" -MaxBytes 6 -Download } 'Corrupt/short/oversized transfer published'
    Assert (@(Get-ChildItem -LiteralPath "$testRoot/streamed" -Force).Count -eq 0) 'Failed transfer left partial or final output'
}
[AcquisitionTestFactory]::Body='abc'
$downloaded=(& $acquire -Manifest $manifest -Out "$testRoot/streamed" -MaxBytes 6 -Download)|ConvertFrom-Json
Assert (@($downloaded.files|Where-Object state -eq 'downloaded').Count -eq 2) 'Correct streamed downloads not published'
Assert ([IO.File]::ReadAllText("$testRoot/streamed/ERR1234567_1.fastq.gz") -eq 'abc') 'Published bytes differ'
Write-Host "Acquisition offline tests passed: $testRoot"
