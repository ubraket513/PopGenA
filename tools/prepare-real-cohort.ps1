[CmdletBinding()] param([string]$Out='work/real-validation',[switch]$Download)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if(![IO.Path]::IsPathRooted($Out)){$Out=Join-Path $root $Out}
$Out=[IO.Path]::GetFullPath($Out)
$lock=Get-Content (Join-Path $PSScriptRoot 'real-cohort.lock.json') -Raw | ConvertFrom-Json
function Digest([string]$Path,[string]$Algorithm){
    $h=[Security.Cryptography.HashAlgorithm]::Create($Algorithm);$f=[IO.File]::OpenRead($Path)
    try{([BitConverter]::ToString($h.ComputeHash($f))).Replace('-','').ToLowerInvariant()}finally{$f.Dispose();$h.Dispose()}
}
function Utf8([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding $false))}
function Native([string]$Exe,[string[]]$Arguments){& $Exe @Arguments;if($LASTEXITCODE){throw "Native command failed ($LASTEXITCODE): $Exe"}}
$requests=@($lock.files)+@($lock.metadata)
$total=0L
foreach($r in $requests){
    $u=[uri]$r.url
    if($u.Scheme -ne 'https' -or $u.Host -ne 'ftp.1000genomes.ebi.ac.uk' -or $u.Query -or $u.UserInfo){throw 'Unexpected validation source'}
    if($r.PSObject.Properties['range_start']){
        $bytes=([long][Math]::Floor(($r.bases-1)/$r.line_bases))*$r.line_bytes+(($r.bases-1)%$r.line_bases)+1
        $r | Add-Member -NotePropertyName bytes -NotePropertyValue $bytes
    }
    $total += $r.bytes
}
$plan=@{download_bytes_upper_bound=45000000;budget_bytes=45000000;scratch_bytes=$lock.scratch_reservation_bytes;out=$Out;selection=$lock.selection;source_files_not_whole_downloads=$requests;method='Index-derived HTTP ranges plus UCSC chromosome FASTA; whole source VCF MD5 cannot be verified'}
if(!$Download){$plan | ConvertTo-Json -Depth 8;return}
$volume=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($Out))
if($volume.AvailableFreeSpace -lt $lock.scratch_reservation_bytes){throw 'Insufficient free disk for validation reservation'}
New-Item -ItemType Directory -Force $Out | Out-Null
$guard=[IO.File]::Open((Join-Path $Out 'prepare.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{
    Utf8 (Join-Path $Out 'download-plan.json') (($plan | ConvertTo-Json -Depth 8)+"`n")
    . (Join-Path $PSScriptRoot 'fetch-real-region.ps1')
    $panel=Get-Content (Join-Path $Out 'original-panel.tsv') | Select-Object -Skip 1 | ForEach-Object {
        $v=$_ -split "`t";if($v.Length -ge 3){[pscustomobject]@{sample=$v[0];population=$v[1];superpopulation=$v[2]}}
    }
    if(@($panel).Count -ne 2504 -or @($panel.sample | Sort-Object -Unique).Count -ne 2504){throw 'Original panel identity/count changed'}
    $selected=@(foreach($pop in @('AFR','AMR','EAS','EUR','SAS')){$panel | Where-Object superpopulation -eq $pop | Sort-Object sample | Select-Object -First 40})
    if($selected.Count -ne 200){throw 'Expected 200 selected individuals'}
    Utf8 (Join-Path $Out 'selected.txt') (($selected.sample -join "`n")+"`n")
    Utf8 (Join-Path $Out 'samples.tsv') ("sample`tpopulation`n"+(($selected | ForEach-Object {"$($_.sample)`t$($_.population)"}) -join "`n")+"`n")
    Utf8 (Join-Path $Out 'selection.tsv') ("sample`tpopulation`tsuperpopulation`n"+(($selected | ForEach-Object {"$($_.sample)`t$($_.population)`t$($_.superpopulation)"}) -join "`n")+"`n")
    $samtools=Join-Path $root '.deps/ucrt64/bin/samtools.exe';$bcftools=Join-Path $root '.deps/ucrt64/bin/bcftools.exe'
    Native $samtools @('faidx',$fasta)
    $bcf=Join-Path $Out 'cohort.bcf'
    Native $bcftools @('view','-r','chr21:15000000-16000000','-S',(Join-Path $Out 'selected.txt'),'-m2','-M2','-v','snps','-f','PASS','-Ob','-o',$bcf, $vcf)
    Native $bcftools @('index','-f',$bcf)
    $count=& $bcftools index -n $bcf;if($LASTEXITCODE){throw 'Cannot count subset'}
    if([long]$count -lt 10000 -or [long]$count -gt 50000){throw "Subset outside planned 10k-50k SNP validation size: $count"}
    $config=@{
        schema_version=1;workflow_type='genotypes';work_dir=(Join-Path $Out 'analysis');assembly='GRCh38 chr21; NYGC 20201028 phased release'
        input=$bcf;reference=$fasta;reference_index=($fasta+'.fai');samples=(Join-Path $Out 'samples.tsv')
        resources=@{threads=8;memory_mb=6144};qc=@{min_dp=0;min_gq=0;sample_missing=0.1;variant_missing=0.1}
        analysis=@{pcs=5;pca_maf=0.05;kinship_maf=0.05;kinship_threshold=0.0884;relatedness_policy='retain';ld_window=50;ld_step=5;ld_r2=0.2;threads=2;memory_mb=4096}
    }
    Utf8 (Join-Path $Out 'config.json') (($config | ConvertTo-Json -Depth 8)+"`n")
    $provenance=@{source_lock_sha256=(Digest (Join-Path $PSScriptRoot 'real-cohort.lock.json') 'SHA256');prepared_utc=[DateTime]::UtcNow.ToString('o');samples=200;sites=[long]$count;reference_sha256=(Digest $fasta 'SHA256');input_sha256=(Digest $bcf 'SHA256');selection=$lock.selection;quality_policy='Phased release GT only; DP/GQ filters explicitly disabled, not synthesized';acquisition='Indexed byte ranges: index MD5 verified, source whole-file MD5 not verified; per-range SHA256 recorded';scope='Single-region integration check; not genome-wide relatedness or population inference'}
    Utf8 (Join-Path $Out 'prepared.json') (($provenance | ConvertTo-Json -Depth 8)+"`n")
    Write-Host "Prepared real-data genotype validation: $Out/config.json"
}finally{$guard.Dispose()}
