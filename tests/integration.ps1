$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$testRoot = Join-Path $root ('build/integration-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $testRoot | Out-Null
$exe = Join-Path $root 'build/popgen.exe'
$bcf = Join-Path $root '.deps/ucrt64/bin/bcftools.exe'
$vcf = Join-Path $root 'tests/fixtures/cohort.vcf'
$meta = Join-Path $root 'tests/fixtures/samples.tsv'
$encoding = New-Object System.Text.UTF8Encoding($false)
function Get-FileHash([string]$LiteralPath) {
    $stream=[IO.File]::OpenRead($LiteralPath);$hash=[Security.Cryptography.SHA256]::Create()
    try { @{Hash=([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-','')} }
    finally { $stream.Dispose();$hash.Dispose() }
}
function Assert($condition,[string]$message) { if (!$condition) { throw $message } }
function Run-Stats([string]$inputFile,[string]$outputDir,[string[]]$extra=@(),[bool]$fail=$false) {
    # File redirection keeps expected stderr errors independent of PowerShell's native error policy.
    $previous=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        & $exe stats --input $inputFile --out $outputDir @extra 1> "$testRoot/stdout.txt" 2> "$testRoot/stderr.txt"
        $code=$LASTEXITCODE
    } finally { $ErrorActionPreference=$previous }
    if($fail){Assert ($code -ne 0) 'Expected failure';Assert (!(Test-Path $outputDir)) 'Failed analysis published outputs'}
    else {if($code -ne 0){throw "Analysis failed: $(Get-Content "$testRoot/stderr.txt" -Raw)"}}
}
Run-Stats $vcf "$testRoot/plain" @('--samples',$meta)
foreach($name in 'samples.tsv','populations.tsv') {
    $actual=[IO.File]::ReadAllText("$testRoot/plain/$name").Replace("`r`n","`n")
    $expected=[IO.File]::ReadAllText("$root/tests/golden/$name").Replace("`r`n","`n")
    Assert ($actual -ceq $expected) "Independent golden mismatch: $name"
}
$p=Get-Content "$testRoot/plain/provenance.json" -Raw|ConvertFrom-Json
Assert ($p.eligible_sites -eq 5 -and $p.records -eq 9) 'Record accounting mismatch'
Assert ($p.skipped.non_autosomal -eq 1 -and $p.skipped.not_biallelic_snp -eq 2 -and $p.skipped.site_filter -eq 1) 'Skip accounting mismatch'
$sites=Import-Csv "$testRoot/plain/sites.tsv" -Delimiter "`t"
Assert ($sites[0].observed_heterozygosity -eq '0.333333333333' -and $sites[0].expected_heterozygosity -eq '0.5') 'First-site estimator mismatch'
Assert ($sites[2].called -eq '0' -and $sites[2].alt_frequency -eq 'NA') 'All-missing site mishandled'
& $bcf view -Ob -o "$testRoot/cohort.bcf" $vcf
Assert ($LASTEXITCODE -eq 0) 'Native bcftools conversion failed'
& $bcf view -Oz -o "$testRoot/cohort.vcf.gz" $vcf
Assert ($LASTEXITCODE -eq 0) 'Native compressed VCF conversion failed'
foreach($format in 'bcf','vcf.gz') {
    Run-Stats "$testRoot/cohort.$format" "$testRoot/$format" @('--samples',$meta,'--threads','1')
    foreach($name in 'samples.tsv','sites.tsv','populations.tsv','population_sites.tsv') {
        Assert ((Get-FileHash "$testRoot/plain/$name").Hash -eq (Get-FileHash "$testRoot/$format/$name").Hash) "Format/thread mismatch: $format $name"
    }
}
Run-Stats $vcf "$testRoot/quality" @('--samples',$meta,'--min-dp','10','--min-gq','20')
$q=Import-Csv "$testRoot/quality/samples.tsv" -Delimiter "`t"
Assert ($q[0].called -eq '2' -and $q[0].quality_filtered -eq '2') 'DP/absent quality masking incorrect'
Assert ($q[2].called -eq '2' -and $q[2].quality_filtered -eq '1') 'GQ masking incorrect'
$before=(Get-FileHash "$testRoot/plain/samples.tsv").Hash
Run-Stats $vcf "$testRoot/plain" @('--samples',$meta,'--replace')
Assert ($before -eq (Get-FileHash "$testRoot/plain/samples.tsv").Hash) 'Replacement changed results'
$unicode = Join-Path $testRoot ('space & ' + [char]0xC0D8 + [char]0xD50C)
New-Item -ItemType Directory $unicode | Out-Null
Copy-Item $vcf "$unicode/input.vcf"
Run-Stats "$unicode/input.vcf" "$unicode/result" @('--samples',$meta)
Assert ((Get-FileHash "$unicode/result/samples.tsv").Hash -eq $before) 'Unicode/space path mismatch'
$badMeta="$testRoot/bad.tsv"
[IO.File]::WriteAllText($badMeta,"sample`tpopulation`nS1`tA`nS1`tB`n",$encoding)
Run-Stats $vcf "$testRoot/bad-meta" @('--samples',$badMeta) $true
$text=[IO.File]::ReadAllText($vcf)
[IO.File]::WriteAllText("$testRoot/bad.vcf",$text.Replace('0/0:20:50','0/8:20:50'),$encoding)
Run-Stats "$testRoot/bad.vcf" "$testRoot/bad-allele" @() $true
[IO.File]::WriteAllText("$testRoot/truncated.vcf",$text + "1`t95`tbad`tA`tG`n",$encoding)
Run-Stats "$testRoot/truncated.vcf" "$testRoot/bad-record" @() $true
$bytes=[IO.File]::ReadAllBytes("$testRoot/cohort.bcf")
[IO.File]::WriteAllBytes("$testRoot/truncated.bcf",$bytes[0..($bytes.Length-29)])
Run-Stats "$testRoot/truncated.bcf" "$testRoot/bad-compressed" @() $true
$variants=@{
    'duplicate-sample'=$text.Replace("`tS4`n","`tS1`n").Replace("`tS4`r`n","`tS1`r`n")
    'wrong-quality-type'=$text.Replace('ID=GQ,Number=1,Type=Integer','ID=GQ,Number=1,Type=Float')
    'no-eligible'=$text.Replace("`n1`t","`nX`t").Replace("`nchr2`t","`nX`t")
    'empty'=''
}
foreach($entry in $variants.GetEnumerator()) {
    $file=Join-Path $testRoot ($entry.Key+'.vcf')
    [IO.File]::WriteAllText($file,$entry.Value,$encoding)
    Run-Stats $file (Join-Path $testRoot ('invalid-'+$entry.Key)) @('--min-gq','20') $true
}
# Failure while replacing must preserve the prior complete result.
$previous=$ErrorActionPreference
try {
    $ErrorActionPreference='Continue'
    & $exe stats --input "$testRoot/bad.vcf" --out "$testRoot/plain" --replace 1> "$testRoot/replace-out.txt" 2> "$testRoot/replace-err.txt"
    $code=$LASTEXITCODE
} finally {$ErrorActionPreference=$previous}
Assert ($code -ne 0 -and (Get-FileHash "$testRoot/plain/samples.tsv").Hash -eq $before) 'Failed replacement damaged prior results'
[IO.File]::WriteAllText("$testRoot/plain/keep.txt",'user data',$encoding)
$previous=$ErrorActionPreference
try {
    $ErrorActionPreference='Continue'
    & $exe stats --input $vcf --out "$testRoot/plain" --replace 1> "$testRoot/extra-out.txt" 2> "$testRoot/extra-err.txt"
    $code=$LASTEXITCODE
} finally {$ErrorActionPreference=$previous}
Assert ($code -ne 0 -and [IO.File]::ReadAllText("$testRoot/plain/keep.txt") -eq 'user data') 'Replacement accepted unowned additional files'
Push-Location $testRoot
try {Run-Stats $vcf "$testRoot/other-cwd" @('--samples',$meta)} finally {Pop-Location}
Assert ((Get-FileHash "$testRoot/other-cwd/samples.tsv").Hash -eq $before) 'Result depends on caller directory'
Assert (@(Get-ChildItem $testRoot -Filter '.popgen-stage-*').Count -eq 0) 'Failed stage was not cleaned up'
Write-Host "Integration checks passed; artifacts: $testRoot"
