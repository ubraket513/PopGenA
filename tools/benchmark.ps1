[CmdletBinding()] param([ValidateRange(1,100000)][int]$Samples=1000,[ValidateRange(1,10000)][int]$Sites=1000,[string]$Out='')
$ErrorActionPreference='Stop';$root=Split-Path $PSScriptRoot -Parent
if(!$Out){$Out=Join-Path $root "work/benchmark-$Samples-$Sites"}
$Out=[IO.Path]::GetFullPath($Out);New-Item -ItemType Directory -Force $Out | Out-Null
$fixture=Join-Path $root 'build/benchmark-fixture.exe';$exe=Join-Path $root 'build/popgen.exe'
if(!(Test-Path $fixture)){throw 'Build with make.ps1 benchmark-fixture first'}
$config=@{schema_version=1;work_dir=(Join-Path $Out 'workflow');inputs=@{};resources=@{threads=4;memory_mb=4096};tools=@{fixture=@{path=$fixture;version_args=@('--version')}};tasks=@(
    @{id='generate';kind='command';pool='heavy';memory_mb=2048;timeout_seconds=1800;commands=@(@{argv=@('fixture',[string]$Samples,[string]$Sites,'{out}/cohort.bcf');threads=1});outputs=@('cohort.bcf','expected.json');stdout='expected.json'},
    @{id='stats';kind='stats';depends_on=@('generate');input='{task:generate}/cohort.bcf';memory_mb=2048;timeout_seconds=1800;hts_threads=2}
)}
$path=Join-Path $Out 'config.json';[IO.File]::WriteAllText($path,($config | ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding $false))
& $exe run --config $path;if($LASTEXITCODE){throw 'Benchmark workflow failed'}
$states=@(Get-ChildItem (Join-Path $Out 'workflow/state') -Filter '*.json' | ForEach-Object {Get-Content $_.FullName -Raw | ConvertFrom-Json})
$generation=$states | Where-Object task -eq 'generate'
$stats=$states | Where-Object task -eq 'stats'
if(!$generation){$generation=Get-Content (Join-Path $Out 'workflow/state/generate.json') -Raw | ConvertFrom-Json}
if(!$stats){$stats=Get-Content (Join-Path $Out 'workflow/state/stats.json') -Raw | ConvertFrom-Json}
$truth=Get-Content (Join-Path $generation.result_dir 'expected.json') -Raw | ConvertFrom-Json
$rows=Import-Csv (Join-Path $stats.result_dir 'samples.tsv') -Delimiter "`t"
if(@($rows).Count -ne $Samples){throw 'Benchmark sample count differs'}
foreach($mapping in @(@('called','called'),@('heterozygous','heterozygous'),@('alt_alleles','alternate_alleles'),@('missing','missing'))){
    $sum=0L;foreach($row in $rows){$sum += [long]$row.($mapping[0])}
    if($sum -ne $truth.($mapping[1])){throw "Benchmark count mismatch: $($mapping[0])"}
}
$bytes=(Get-ChildItem (Join-Path $Out 'workflow') -Recurse -File | Measure-Object Length -Sum).Sum
$report=@{samples=$Samples;sites=$Sites;genotypes=([long]$Samples*$Sites);checked_counts=$truth;generate=$generation.process;stats=$stats.process;retained_work_bytes=$bytes;memory_metric='Windows job peak committed bytes, not RSS';scope='Streaming statistics only; no KING/PCA scalability claim'}
$result=Join-Path $Out 'benchmark.json';[IO.File]::WriteAllText($result,($report | ConvertTo-Json -Depth 12)+"`n",(New-Object Text.UTF8Encoding $false))
Write-Host "Verified benchmark report: $result"
