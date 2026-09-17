$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
$testRoot=Join-Path $project ('build/mask test & '+[char]0xC0D8+'-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $testRoot | Out-Null
$exe=Join-Path $project 'build/popgen.exe'
$bcftools=Join-Path $project '.deps/ucrt64/bin/bcftools.exe'
$enc=New-Object Text.UTF8Encoding($false)
function Assert($value,[string]$message){if(!$value){throw $message}}
function Invoke-CLI([string[]]$argv,[bool]$fail=$false){
    $old=$ErrorActionPreference
    try{$ErrorActionPreference='Continue';& $exe @argv 1> "$testRoot/stdout.txt" 2> "$testRoot/stderr.txt";$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
    if($fail){Assert ($code -ne 0) 'Expected mask failure'}elseif($code){throw "Mask failed: $(Get-Content "$testRoot/stderr.txt" -Raw)"}
}
function BCF([string[]]$argv){
    $old=$ErrorActionPreference
    try{$ErrorActionPreference='Continue';$text=& $bcftools @argv 2> "$testRoot/bcf.stderr.txt";$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
    if($code){throw "bcftools failed: $(Get-Content "$testRoot/bcf.stderr.txt" -Raw)"};return $text
}
function Digest([string]$path){
    $algorithm=[Security.Cryptography.SHA256]::Create();$stream=[IO.File]::OpenRead($path)
    try{[BitConverter]::ToString($algorithm.ComputeHash($stream))}finally{$stream.Dispose();$algorithm.Dispose()}
}
$header=@'
##fileformat=VCFv4.3
##contig=<ID=1,length=1000>
##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
##FORMAT=<ID=DP,Number=1,Type=Integer,Description="Depth">
##FORMAT=<ID=GQ,Number=1,Type=Integer,Description="Quality">
##INFO=<ID=AC,Number=A,Type=Integer,Description="Allele count">
##INFO=<ID=AN,Number=1,Type=Integer,Description="Allele number">
##INFO=<ID=AF,Number=A,Type=Float,Description="Allele frequency">
##INFO=<ID=NS,Number=1,Type=Integer,Description="Samples">
#CHROM POS ID REF ALT QUAL FILTER INFO FORMAT A B
'@
function Fixture([string]$name,[string[]]$rows,[string]$customHeader=$header){
    $vcf=Join-Path $testRoot ($name+'.vcf');$bcf=Join-Path $testRoot ($name+'.bcf')
    $text=$customHeader.Replace('#CHROM POS ID REF ALT QUAL FILTER INFO FORMAT A B',("#CHROM`tPOS`tID`tREF`tALT`tQUAL`tFILTER`tINFO`tFORMAT`tA`tB"))
    $lines=@($text.TrimEnd())+@($rows|ForEach-Object {$_ -replace ' ',"`t"})
    [IO.File]::WriteAllText($vcf,($lines -join "`n")+"`n",$enc)
    BCF @('view','--no-version','-Ob','-o',$bcf,$vcf)|Out-Null
    return $bcf
}
$inputBCF=Fixture 'calls' @(
    '1 10 phase A C . PASS AC=2;AN=4;AF=0.5;NS=2 GT:DP:GQ 0|1:20:30 1|0:20:30',
    '1 20 low A C . . AC=2;AN=4;AF=0.5;NS=2 GT:DP:GQ 0/1:9:30 0/1:20:19',
    '1 30 missing-quality A C . PASS . GT:DP:GQ 0/1:.:30 0/1:20:.',
    '1 40 ploidy A C . PASS . GT:DP:GQ 1:20:30 0/1/1:20:30',
    '1 50 missing-gt A C . PASS . GT:DP:GQ 0/.:20:30 ./.:20:30'
)
$output=Join-Path $testRoot 'masked.bcf'
Invoke-CLI @('mask','--input',$inputBCF,'--out',$output,'--min-dp','10','--min-gq','20')
$report=Get-Content -LiteralPath "$testRoot/stdout.txt" -Raw -Encoding UTF8|ConvertFrom-Json
Assert ($report.kept -eq 5 -and $report.sample_count -eq 2) 'Mask record/sample counts wrong'
Assert ($report.genotypes.kept -eq 2 -and $report.genotypes.quality -eq 4 -and $report.genotypes.unsupported -eq 2 -and $report.genotypes.missing -eq 2) 'Mask reason counts wrong'
$rows=@(BCF @('query','-f','%POS\t%ID\t%INFO[\t%GT]\n',$output))
Assert ($rows[0] -ceq "10`tphase`t.`t0|1`t1|0") 'Phase, ID, or removal of stale INFO failed'
foreach($row in $rows[1..4]){Assert ($row.EndsWith("`t./.`t./.")) 'Rejected calls were not diploid missing'}
Assert ((BCF @('query','-r','1:20-30','-f','%POS\n',$output)) -join ',' -ceq '20,30') 'CSI regional access failed'
Assert ($report.samples.Count -eq 2 -and $report.samples[0].masked -eq 4 -and $report.samples[1].masked -eq 4) 'Per-sample masking counts wrong'
# A requested quality field absent from the header/records masks every call.
$noQualityHeader=($header -split "`r?`n"|Where-Object {$_ -notmatch '^##FORMAT=<ID=(DP|GQ),'}) -join "`n"
$noQuality=Fixture 'no-quality' @('1 10 . A C . PASS . GT 0|1 1/1') $noQualityHeader
foreach($option in @('--min-dp','--min-gq')){
    $out=Join-Path $testRoot ($option.TrimStart('-')+'.bcf')
    Invoke-CLI @('mask','--input',$noQuality,'--out',$out,$option,'1')
    Assert ((BCF @('query','-f','[%GT,]',$out)) -ceq './.,./.,') 'Absent requested quality did not mask calls'
}
# Threshold zero disables quality requirements.
$disabled=Join-Path $testRoot 'disabled.bcf'
Invoke-CLI @('mask','--input',$noQuality,'--out',$disabled)
Assert ((BCF @('query','-f','[%GT,]',$disabled)) -ceq '0|1,1/1,') 'Disabled quality thresholds changed GT'
# Wrong declared type and vector-valued scalar quality are explicit errors.
$floatDP=Fixture 'float-dp' @('1 10 . A C . PASS . GT:DP 0/1:12.5 1/1:20.5') ($header.Replace('ID=DP,Number=1,Type=Integer','ID=DP,Number=1,Type=Float'))
$vectorDP=Fixture 'vector-dp' @('1 10 . A C . PASS . GT:DP 0/1:12,13 1/1:20,21') ($header.Replace('ID=DP,Number=1','ID=DP,Number=2'))
$negativeDP=Fixture 'negative-dp' @('1 10 . A C . PASS . GT:DP 0/1:-1 1/1:20')
foreach($bad in @($floatDP,$vectorDP,$negativeDP)){
    $out=$bad+'.masked.bcf';Invoke-CLI @('mask','--input',$bad,'--out',$out,'--min-dp','1') $true
    Assert (!(Test-Path -LiteralPath $out)) 'Malformed quality published output'
}
$unsorted=Fixture 'unsorted' @('1 20 . A C . PASS . GT 0/1 1/1','1 10 . A C . PASS . GT 0/1 1/1')
Invoke-CLI @('mask','--input',$unsorted,'--out',"$testRoot/unsorted.masked.bcf") $true
Assert (!(Test-Path -LiteralPath "$testRoot/unsorted.masked.bcf")) 'Unsorted input published output'
# Drop the BGZF EOF block while preserving otherwise readable records.
$truncated=Join-Path $testRoot 'truncated.bcf';$bytes=[IO.File]::ReadAllBytes($inputBCF)
Assert ($bytes.Length -gt 28) 'Fixture too small to truncate'
[IO.File]::WriteAllBytes($truncated,[byte[]]$bytes[0..($bytes.Length-29)])
Invoke-CLI @('mask','--input',$truncated,'--out',"$testRoot/truncated.masked.bcf") $true
Assert (!(Test-Path -LiteralPath "$testRoot/truncated.masked.bcf")) 'Truncated input published output'
# Existing outputs and existing index-only paths must retain their exact bytes.
$before=Digest $output;$indexBefore=Digest ($output+'.csi')
Invoke-CLI @('mask','--input',$inputBCF,'--out',$output) $true
Assert ((Digest $output) -ceq $before) 'Existing BCF changed'
Assert ((Digest ($output+'.csi')) -ceq $indexBefore) 'Existing CSI changed'
$indexOnly=Join-Path $testRoot 'index-only.bcf'
[IO.File]::WriteAllText($indexOnly+'.csi','owned elsewhere',$enc)
$indexDigest=Digest ($indexOnly+'.csi')
Invoke-CLI @('mask','--input',$inputBCF,'--out',$indexOnly) $true
Assert (!(Test-Path -LiteralPath $indexOnly) -and (Digest ($indexOnly+'.csi')) -ceq $indexDigest) 'Existing index-only path was changed'
Write-Host "Adversarial genotype masking checks passed: $testRoot"
