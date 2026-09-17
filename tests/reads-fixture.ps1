param([string]$OutputDirectory=(Join-Path $PSScriptRoot 'fixtures/reads'))
$ErrorActionPreference='Stop'
$enc=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force $OutputDirectory|Out-Null
$OutputDirectory=(Resolve-Path -LiteralPath $OutputDirectory).Path
function Save([string]$name,[string]$value){[IO.File]::WriteAllText((Join-Path $OutputDirectory $name),$value,$enc)}
function ReverseComplement([string]$seq){$chars=$seq.ToCharArray();[array]::Reverse($chars);$map=@{A='T';C='G';G='C';T='A'};return -join @($chars|ForEach-Object{$map[[string]$_]})}
$state=[uint64]1729;$bases='ACGT';$reference=New-Object Text.StringBuilder
for($i=0;$i -lt 10000;$i++){$state=($state*[uint64]1664525+[uint64]1013904223)%[uint64]4294967296;[void]$reference.Append($bases[[int](($state -shr 24)%4)])}
$ref=$reference.ToString();Save 'reference.fa' (">1`n"+$ref+"`n")
$variants=@(1000,2000,3000)
$alt=@{};foreach($position in $variants){$alt[$position]=$bases[($bases.IndexOf($ref[$position-1])+1)%4]}
$runs=@(
 @{id='A_lane1';sample='A';library='A_lib1';shift=0},
 @{id='A_lane2';sample='A';library='A_lib1';shift=0},
 @{id='A_library2';sample='A';library='A_lib2';shift=0},
 @{id='B_lane1';sample='B';library='B_lib1';shift=0},
 @{id='C_lane1';sample='C';library='C_lib1';shift=0}
)
$truth=@{A=@('0/0','0/1','1/1');B=@('0/1','0/0','0/1');C=@('1/1','./.','0/0')}
foreach($run in $runs){
 $r1=New-Object Text.StringBuilder;$r2=New-Object Text.StringBuilder;$serial=0
 for($v=0;$v -lt $variants.Count;$v++){
  $position=$variants[$v];$gt=$truth[$run.sample][$v];if($gt -eq './.'){continue}
  for($j=0;$j -lt 24;$j++){
   $start=$position-110+$j;$first=$ref.Substring($start-1,150).ToCharArray()
   if($gt -eq '1/1' -or ($gt -eq '0/1' -and ($j%2 -eq 1))){$first[$position-$start]=$alt[$position]}
   $second=ReverseComplement $ref.Substring($start-1+200,150);$name=$run.id+'_'+(++$serial);$quality='I'*150
   [void]$r1.Append("@$name/1`n$(-join $first)`n+`n$quality`n");[void]$r2.Append("@$name/2`n$second`n+`n$quality`n")
  }
 }
 # Known low-quality pair, removed by fastp rather than used for calling.
 $name=$run.id+'_lowq';$q='!'*150;$first=$ref.Substring(4500,150);$second=ReverseComplement $ref.Substring(4700,150)
 [void]$r1.Append("@$name/1`n$first`n+`n$q`n");[void]$r2.Append("@$name/2`n$second`n+`n$q`n")
 Save ($run.id+'_1.fastq') $r1.ToString();Save ($run.id+'_2.fastq') $r2.ToString()
}
Save 'samples.tsv' "sample`tpopulation`nC`tP2`nA`tP1`nB`tP1`n"
$hash=[Security.Cryptography.SHA256]::Create();$stream=[IO.File]::OpenRead((Join-Path $OutputDirectory 'reference.fa'))
try{$referenceHash=([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$stream.Dispose();$hash.Dispose()}
$expected=@{schema_version=1;reference_sha256=$referenceHash;samples=@('A','B','C');runs=5;libraries=4;positions=$variants;genotypes=$truth;low_quality_pairs_per_run=1;duplicate_pairs_same_library=72;notes='A_lane1/A_lane2 share a library and duplicate every fragment. A_library2 is an independent library and must not be deduplicated against A_lib1. C has no coverage at site 2000.'}
Save 'expected.json' (($expected|ConvertTo-Json -Depth 10)+"`n")
Write-Host "Deterministic reads fixture: $OutputDirectory"
