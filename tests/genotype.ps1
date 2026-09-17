$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
$testRoot=Join-Path $project ('build/genotype test & '+[char]0xC0D8+'-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $testRoot | Out-Null
$exe=Join-Path $project 'build/popgen.exe'
$bcftools=Join-Path $project '.deps/ucrt64/bin/bcftools.exe'
$fixture=Join-Path $project 'tests/fixtures/genotype'
$enc=New-Object Text.UTF8Encoding($false)
function Assert($value,[string]$message){if(!$value){throw $message}}
function ReadJson([string]$path){Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json}
function Save($value,[string]$path){[IO.File]::WriteAllText($path,($value|ConvertTo-Json -Depth 40),$enc)}
function Invoke-CLI([string[]]$argv,[bool]$fail=$false){
    $old=$ErrorActionPreference
    try{$ErrorActionPreference='Continue';& $exe @argv 1> "$testRoot/stdout.txt" 2> "$testRoot/stderr.txt";$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
    if($fail){Assert ($code -ne 0) 'Expected CLI failure'}elseif($code){throw "CLI failed: $(Get-Content "$testRoot/stderr.txt" -Raw)"}
}
function BCF([string[]]$argv){
    $old=$ErrorActionPreference
    try{$ErrorActionPreference='Continue';$text=& $bcftools @argv 2> "$testRoot/bcf.stderr.txt";$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
    if($code){throw "bcftools failed: $(Get-Content "$testRoot/bcf.stderr.txt" -Raw)"};return $text
}
function Result([string]$id){(ReadJson "$work/state/$id.json").result_dir}
$c=ReadJson (Join-Path $project 'config/genotype-demo.json')
$c.input=Join-Path $fixture 'cohort.vcf';$c.reference=Join-Path $fixture 'reference.fa';$c.reference_index=$c.reference+'.fai'
$c.samples=Join-Path $fixture 'samples.tsv';$c.work_dir=Join-Path $testRoot 'work';$work=$c.work_dir
$config=Join-Path $testRoot 'config.json';Save $c $config
Invoke-CLI @('plan','--config',$config)
Assert (@(Get-ChildItem "$work/state").Count -eq 0) 'Genotype plan executed tasks'
$plan=ReadJson "$work/plan.json";Assert ($plan.tasks.Count -eq 15) 'Incomplete genotype DAG'
Invoke-CLI @('run','--config',$config)
$mask=ReadJson "$(Result 'mask')/mask.json";$expected=ReadJson "$fixture/expected.json"
Assert ($mask.records -eq $expected.input_records -and $mask.kept -eq 240 -and $mask.sample_count -eq 64) 'Mask record/sample totals wrong'
Assert ($mask.skipped.non_autosomal -eq 1 -and $mask.skipped.not_biallelic_snp -eq 1 -and $mask.skipped.site_filter -eq 1) 'Mask skipped categories wrong'
$selection=ReadJson "$(Result 'select')/selection.json"
Assert (($selection.sample_qc_excluded -join ',') -ceq 'S62,S63') 'Sample missingness exclusions wrong'
Assert ($selection.retained.Count -eq 61 -and $selection.relatedness_excluded.Count -eq 1 -and $selection.retained -contains 'S00' -and $selection.retained -notcontains 'S61') 'Duplicate relatedness exclusion wrong'
$sites=Import-Csv -Delimiter "`t" -LiteralPath "$(Result 'stats')/sites.tsv"
Assert ($sites.Count -eq 238) 'Variant missingness filtering wrong'
Assert (@($sites|Where-Object pos -eq '15').Count -eq 1 -and @($sites|Where-Object pos -eq '20').Count -eq 1) 'Diversity data lost monomorphic/singleton sites'
$samples=Import-Csv -Delimiter "`t" -LiteralPath "$(Result 'stats')/samples.tsv"
Assert ($samples.Count -eq $selection.retained.Count) 'BCF/statistics sample set differs'
$markers=Get-Content -LiteralPath "$(Result 'prune')/data.prune.in"
Assert ($markers -notcontains '1:15:A:C' -and $markers -notcontains '1:20:A:C') 'PCA MAF filter not applied'
Assert ($markers.Count -lt 236 -and $markers.Count -gt 3) 'LD pruning did not remove duplicated loci or removed all markers'
$validation=ReadJson "$(Result 'validate')/validation.json"
Assert ($validation.validated -and $validation.markers -eq $markers.Count -and $validation.relative_eigenpair_residual.Count -eq 3) 'Independent PCA verification absent'
foreach($e in $validation.relative_eigenpair_residual){Assert ($e -lt 0.001) 'PCA covariance residual exceeds tolerance'}
$masked="$(Result 'mask')/masked.bcf"
foreach($case in @(@(25,'S02','./.'),@(30,'S03','./.'),@(35,'S04','./.'),@(40,'S05','./.'),@(45,'S06','0/1'))){
    $gt=BCF @('query','-r',"1:$($case[0])-$($case[0])",'-s',$case[1],'-f','[%GT]\n',$masked)
    Assert ($gt -ceq $case[2]) "Masked genotype wrong: $($case[1])/$($case[0])"
}
# CSI must support actual regional access to published BCF.
$final="$(Result 'bcf')/cohort.bcf"
Assert ((BCF @('query','-r','1:15-20','-f','%POS\n',$final)).Count -eq 2) 'Published CSI is unusable'
$attempt=(ReadJson "$work/state/pca.json").attempt
Push-Location $testRoot
try{Invoke-CLI @('run','--config',$config)}finally{Pop-Location}
Assert ((ReadJson "$work/last-run.json").reused_tasks -eq 15) 'Unchanged genotype run did not fully resume'
Assert ((ReadJson "$work/state/pca.json").attempt -eq $attempt) 'PCA rebuilt on unchanged run'
# Eigenvector signs are arbitrary: independently verified eigenpairs must accept sign flips.
$pca=Result 'pca';$psam="$(Result 'retained')/data.psam";$flipped=Join-Path $testRoot 'flipped.eigenvec'
$rows=Get-Content -LiteralPath "$pca/data.eigenvec";$changed=@($rows[0])
foreach($line in $rows[1..($rows.Count-1)]){$cells=$line -split '\s+';for($i=2;$i -lt $cells.Count;$i++){$cells[$i]=(-[double]::Parse($cells[$i],[Globalization.CultureInfo]::InvariantCulture)).ToString('G17',[Globalization.CultureInfo]::InvariantCulture)};$changed+=($cells -join "`t")}
[IO.File]::WriteAllText($flipped,($changed -join "`n")+"`n",$enc)
$argsCheck=@('pca-check','--psam',$psam,'--pcs','3','--vectors',$flipped,'--values',"$pca/data.eigenval",'--bcf',$final,'--markers',"$(Result 'prune')/data.prune.in")
Invoke-CLI $argsCheck
$bad=Join-Path $testRoot 'bad.eigenval';[IO.File]::WriteAllText($bad,"100`n99`n98`n",$enc);$argsCheck[8]=$bad
Invoke-CLI $argsCheck $true
Assert ((Get-Content "$testRoot/stderr.txt" -Raw) -match 'eigenpair differs') 'Incorrect eigenvalue test failed for an unrelated reason'
# Output damage reruns downstream tasks, preserving independent upstream generations.
$importAttempt=(ReadJson "$work/state/import.json").attempt
[IO.File]::AppendAllText("$pca/data.eigenvec","corrupted`n",$enc)
Invoke-CLI @('run','--config',$config)
Assert ((ReadJson "$work/state/pca.json").attempt -ne $attempt) 'Corrupted PCA output reused'
Assert ((ReadJson "$work/state/import.json").attempt -eq $importAttempt) 'PCA damage rebuilt unrelated import'
# Explicit retain policy preserves the duplicate; existing upstream QC can be reused.
$c.analysis.relatedness_policy='retain';Save $c $config;Invoke-CLI @('run','--config',$config)
$kept=ReadJson "$(Result 'select')/selection.json"
Assert ($kept.retained.Count -eq 62 -and $kept.relatedness_excluded.Count -eq 0 -and $kept.reported_pairs -gt 0) 'Explicit retain policy ignored'
Assert ((ReadJson "$work/state/import.json").attempt -eq $importAttempt) 'Policy change rebuilt import'
# Small LD windows get a usable default step rather than failing later in PLINK.
$c.analysis.ld_window=2;$c.analysis.PSObject.Properties.Remove('ld_step');Save $c $config
Invoke-CLI @('run','--config',$config)
Assert ((ReadJson "$work/state/import.json").attempt -eq $importAttempt) 'LD-only change rebuilt import'
# Unknown scientific settings and omitted relatedness policy fail before a workflow can run.
$c.analysis|Add-Member -NotePropertyName 'invented' -NotePropertyValue 1;Save $c $config;Invoke-CLI @('plan','--config',$config) $true
$c.analysis.PSObject.Properties.Remove('invented');$c.analysis.PSObject.Properties.Remove('relatedness_policy');Save $c $config;Invoke-CLI @('plan','--config',$config) $true
# Existing mask products must never be truncated by a failed repeated invocation.
$before=[IO.File]::ReadAllBytes($masked).Length
Invoke-CLI @('mask','--input',"$(Result 'normalize')/normalized.bcf",'--out',$masked) $true
Assert ([IO.File]::ReadAllBytes($masked).Length -eq $before) 'Mask overwrote an existing product'
Write-Host "Genotype QC/PCA integration checks passed: $testRoot"
