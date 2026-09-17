$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
$root=Join-Path $project ('build/reads test & '+[char]0xC0D8+'-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root|Out-Null
$enc=New-Object Text.UTF8Encoding($false)
$exe=Join-Path $project 'build/popgen.exe';$bcf=Join-Path $project '.deps/ucrt64/bin/bcftools.exe'
function Assert($ok,[string]$message){if(!$ok){throw $message}}
function ReadJson([string]$path){Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json}
function Save($value,[string]$path){[IO.File]::WriteAllText($path,($value|ConvertTo-Json -Depth 40),$enc)}
function Invoke-CLI([string[]]$argv,[bool]$fail=$false){
 $old=$ErrorActionPreference
 try{$ErrorActionPreference='Continue';& $exe @argv 1> "$root/stdout.txt" 2> "$root/stderr.txt";$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
 if($fail){Assert ($code -ne 0) 'Expected CLI failure'}elseif($code){throw "CLI failed: $(Get-Content "$root/stderr.txt" -Raw)"}
}
function Query([string[]]$argv){
 $old=$ErrorActionPreference
 try{$ErrorActionPreference='Continue';$result=& $bcf @argv 2> "$root/bcf.stderr.txt";$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
 if($code){throw "bcftools failed: $(Get-Content "$root/bcf.stderr.txt" -Raw)"};return $result
}
function Result([string]$id){(ReadJson "$work/state/$id.json").result_dir}
$fixture=Join-Path $root 'input data';New-Item -ItemType Directory $fixture|Out-Null
Copy-Item -Path (Join-Path $project 'tests/fixtures/reads/*') -Destination $fixture
$expected=ReadJson "$fixture/expected.json"
$c=ReadJson (Join-Path $project 'config/reads-demo.json')
$c.reference=Join-Path $fixture 'reference.fa';$c.samples=Join-Path $fixture 'samples.tsv'
foreach($r in $c.runs){$r.read1=Join-Path $fixture ($r.id+'_1.fastq');$r.read2=Join-Path $fixture ($r.id+'_2.fastq')}
$c.work_dir=Join-Path $root 'work';$work=$c.work_dir;$config=Join-Path $root 'config.json';Save $c $config
Invoke-CLI @('plan','--config',$config)
Assert ((ReadJson "$work/plan.json").tasks.Count -eq 40) 'Raw workflow incomplete'
Assert (@(Get-ChildItem "$work/attempts").Count -eq 0) 'Raw plan executed tools'
Invoke-CLI @('run','--config',$config)
$mask="$(Result 'mask')/masked.bcf"
$calls=Query @('query','-f','%POS[\t%GT:%DP]\n',$mask)
$golden=@("1000`t0/0:48`t0/1:24`t1/1:24","2000`t0/1:48`t0/0:24`t./.:0","3000`t1/1:48`t0/1:24`t0/0:24")
Assert (($calls -join "`n") -ceq ($golden -join "`n")) 'Called GT/DP differs from independent FASTQ truth, including zero coverage and duplicate policy'
$selected=Query @('query','-r','1:2000-2000','-s','C','-f','[%GT\t%DP]\n',$mask)
Assert ($selected -ceq "./.`t0") 'No-coverage sample was imputed as reference or CSI does not work'
$alignments=ReadJson "$(Result 'bams')/alignments.json"
Assert ($alignments.samples -eq 3 -and $alignments.libraries.Count -eq 4) 'Run/library/sample identities were collapsed incorrectly'
Assert ($alignments.libraries[0].duplicates -eq 144 -and $alignments.libraries[0].usable_primary_records -eq 144) 'Cross-run duplicates in same library were not marked'
Assert ($alignments.libraries[1].duplicates -eq 0 -and $alignments.libraries[1].usable_primary_records -eq 144) 'Independent library was incorrectly deduplicated'
for($i=1;$i -le 5;$i++){
 $raw=ReadJson "$(Result "r$i-check")/reads.json";$trim=ReadJson "$(Result "r$i-trim-check")/reads.json";$report=ReadJson "$(Result "r$i-trim-check")/fastp.json"
 Assert ($raw.pairs -eq ($trim.pairs+1)) 'fastp did not remove exactly the known low-quality pair'
 Assert ($report.summary.after_filtering.total_reads -eq 2*$trim.pairs -and $report.popgen_report_adapter.paired_counts_validated) 'Normalized fastp report count validation failed'
}
$stats=Import-Csv -LiteralPath "$(Result 'stats')/samples.tsv" -Delimiter "`t"
Assert ($stats.Count -eq 3) 'Raw calls lost sample identities'
Assert ($stats[0].called -eq 3 -and $stats[0].heterozygous -eq 1 -and $stats[1].heterozygous -eq 2 -and $stats[2].called -eq 2 -and $stats[2].missing -eq 1) 'Raw-input diversity denominators differ from independent truth'
$before=(ReadJson "$work/state/call.json").attempt
Push-Location $root
try{Invoke-CLI @('run','--config',$config)}finally{Pop-Location}
Assert ((ReadJson "$work/last-run.json").reused_tasks -eq 40) 'Raw workflow did not resume unchanged'
# An isolated masking change must reuse mapping and joint calling.
$c.qc.min_dp=25;Save $c $config;Invoke-CLI @('run','--config',$config)
Assert ((ReadJson "$work/state/call.json").attempt -eq $before) 'Mask threshold rebuilt alignment/calling'
Assert ((ReadJson "$work/last-run.json").scheduled_tasks -eq 2) 'Mask threshold invalidation was not limited to mask/stats'
$c.qc.min_dp=5;$c.processing.threads=1;Save $c $config;Invoke-CLI @('run','--config',$config)
$mask="$(Result 'mask')/masked.bcf";$single=Query @('query','-f','%POS[\t%GT:%DP]\n',$mask)
Assert (($single -join "`n") -ceq ($golden -join "`n")) 'One- and two-worker pipelines disagree'
# A damaged final BCF is regenerated without rerunning raw-read tools.
$trimAttempt=(ReadJson "$work/state/r1-trim.json").attempt
$bytes=[IO.File]::ReadAllBytes($mask);$bytes[0]=$bytes[0] -bxor 1;[IO.File]::WriteAllBytes($mask,$bytes)
Invoke-CLI @('run','--config',$config)
Assert ((ReadJson "$work/state/r1-trim.json").attempt -eq $trimAttempt -and (ReadJson "$work/last-run.json").scheduled_tasks -eq 2) 'Damaged BCF rerun reached unrelated read tools'
# Configuration errors must be caught before commands are launched.
$saved=$c|ConvertTo-Json -Depth 40
foreach($case in @('duplicate','budget','scratch','zero-depth','unknown')){
 $bad=$saved|ConvertFrom-Json
 switch($case){
  duplicate {$bad.runs[1].read1=$bad.runs[0].read1}
  budget {$bad.limits.input_bytes=1}
  scratch {$bad.limits.scratch_bytes=67108864}
  zero-depth {$bad.qc.min_dp=0}
  unknown {$bad.processing|Add-Member -NotePropertyName 'invented' -NotePropertyValue 1}
 }
 Save $bad "$root/bad.json";Invoke-CLI @('plan','--config',"$root/bad.json") $true
}
# Wrong reference identity fails reference preparation, before mapping.
$bad=$saved|ConvertFrom-Json;$bad.work_dir="$root/wrong-reference";$bad.reference_sha256='0'*64;Save $bad "$root/bad-reference.json"
Invoke-CLI @('run','--config',"$root/bad-reference.json") $true
Assert (!(Test-Path "$root/wrong-reference/state/reference.json") -and !(Test-Path "$root/wrong-reference/state/r1-align.json")) 'Wrong reference published usable results'
# Strict paired FASTQ validation rejects malformed headers, mate count/name mismatches and truncation.
$one=[IO.File]::ReadAllText($c.runs[0].read1);$two=[IO.File]::ReadAllText($c.runs[0].read2)
foreach($case in @('name','header','trailing','short','mate')){
 $data=$one
 switch($case){name {$data=$one.Replace('@A_lane1_1/1','@wrong/1')};header {$data=$one.Substring(1)};trailing {$data=$one+"garbage`n"};short {$data=$one.Substring(0,$one.Length-10)};mate {$data=$one.Replace('/1', '/2')}}
 [IO.File]::WriteAllText("$root/bad.fastq",$data,$enc)
 Invoke-CLI @('raw-fastq','--read1',"$root/bad.fastq",'--read2',$c.runs[0].read2) $true
}
$stream=[IO.File]::Create("$root/truncated.fastq.gz")
$gzip=New-Object IO.Compression.GZipStream($stream,[IO.Compression.CompressionMode]::Compress)
try{$data=$enc.GetBytes($one);$gzip.Write($data,0,$data.Length)}finally{$gzip.Dispose();$stream.Dispose()}
$bytes=[IO.File]::ReadAllBytes("$root/truncated.fastq.gz");[IO.File]::WriteAllBytes("$root/truncated.fastq.gz",$bytes[0..($bytes.Length-9)])
Invoke-CLI @('raw-fastq','--read1',"$root/truncated.fastq.gz",'--read2',$c.runs[0].read2) $true
Write-Host "Native FASTQ-to-genotype checks passed: $root"
