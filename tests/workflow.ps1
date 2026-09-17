$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
Set-Location $project
$testRoot=Join-Path $project ('build/workflow test & '+[char]0xC0D8+'-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $testRoot | Out-Null
$exe=Join-Path $project 'build/popgen.exe'
$helper=Join-Path $project 'build/process-helper.exe'
$encoding=New-Object System.Text.UTF8Encoding($false)
function Assert($ok,[string]$message){if(!$ok){throw $message}}
function Save($value,[string]$path){[IO.File]::WriteAllText($path,($value|ConvertTo-Json -Depth 40),$encoding)}
function Read-Json([string]$path){Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json}
function Hash([string]$path){$h=[Security.Cryptography.SHA256]::Create();$s=[IO.File]::OpenRead($path);try{[BitConverter]::ToString($h.ComputeHash($s))}finally{$s.Dispose();$h.Dispose()}}
function Invoke-CLI([string[]]$arguments,[bool]$fail=$false) {
    $previous=$ErrorActionPreference
    try{$ErrorActionPreference='Continue';& $exe @arguments 1> "$testRoot/cli.stdout.txt" 2> "$testRoot/cli.stderr.txt";$code=$LASTEXITCODE}
    finally{$ErrorActionPreference=$previous}
    if($fail){Assert ($code -ne 0) 'Expected command failure'}
    elseif($code -ne 0){throw "CLI failed: $(Get-Content "$testRoot/cli.stderr.txt" -Raw)"}
}
function Demo([string]$work) {
    @{
        schema_version=1;work_dir=$work;resources=@{threads=8;memory_mb=4096;light_jobs=1}
        inputs=@{cohort="$testRoot/cohort.vcf";samples=(Join-Path $project 'tests/fixtures/samples.tsv')}
        tools=@{bcftools=@{path=(Join-Path $project '.deps/ucrt64/bin/bcftools.exe');version_args=@('--version')}}
        tasks=@(
            @{id='convert';kind='command';pool='heavy';memory_mb=512;commands=@(
                @{argv=@('bcftools','view','-Ou','{input:cohort}');threads=1},
                @{argv=@('bcftools','view','-Ob','-o','{out}/cohort.bcf','-');threads=1}
            );outputs=@('cohort.bcf')},
            @{id='stats';kind='stats';depends_on=@('convert');input='{task:convert}/cohort.bcf';samples='{input:samples}';hts_threads=1;min_dp=0;memory_mb=512}
        )
    }
}
Copy-Item 'tests/fixtures/cohort.vcf' "$testRoot/cohort.vcf"
$config=Join-Path $testRoot 'demo.json';$work=Join-Path $testRoot 'work';$c=Demo $work;Save $c $config
Invoke-CLI @('plan','--config',$config)
Assert (@(Get-ChildItem "$work/state").Count -eq 0) 'Planning created a completion record'
Assert (@(Get-ChildItem "$work/attempts").Count -eq 0) 'Planning launched a task/probe'
Invoke-CLI @('run','--config',$config)
$first=Read-Json "$work/state/convert.json";$stats=Read-Json "$work/state/stats.json"
Assert ([IO.File]::ReadAllText((Join-Path $stats.result_dir 'samples.tsv')).Replace("`r`n","`n") -ceq [IO.File]::ReadAllText((Join-Path $project 'tests/golden/samples.tsv')).Replace("`r`n","`n")) 'Workflow scientific output differs from independent golden'
Assert ($first.process.exit_codes.Count -eq 2 -and $first.process.exit_codes[0] -eq 0 -and $first.process.exit_codes[1] -eq 0) 'Pipeline process statuses missing'
Assert ($first.tool_versions.bcftools.stdout -match 'bcftools 1.24') 'Tool version was not recorded'
Invoke-CLI @('run','--config',$config)
$run=Read-Json "$work/last-run.json"
Assert ($run.reused_tasks -eq 2 -and $run.scheduled_tasks -eq 0) 'Unchanged workflow did not reuse outputs'
Assert ((Read-Json "$work/state/stats.json").attempt -eq $stats.attempt) 'Unchanged result was rebuilt'
$c.tasks[1].min_dp=10;Save $c $config;Invoke-CLI @('run','--config',$config)
Assert ((Read-Json "$work/state/convert.json").attempt -eq $first.attempt) 'Downstream-only config change rebuilt upstream task'
Assert ((Read-Json "$work/state/stats.json").attempt -ne $stats.attempt) 'Config change did not invalidate task'
$inputText=[IO.File]::ReadAllText("$testRoot/cohort.vcf")
[IO.File]::WriteAllText("$testRoot/cohort.vcf",$inputText.Replace('##fileformat=VCFv4.3',"##fileformat=VCFv4.3`n##source=changed"),$encoding)
Invoke-CLI @('run','--config',$config)
$second=Read-Json "$work/state/convert.json"
Assert ($second.attempt -ne $first.attempt) 'Changed input was reused'
$bcf=Join-Path $second.result_dir 'cohort.bcf';$mtime=[IO.File]::GetLastWriteTimeUtc($bcf);$bytes=[IO.File]::ReadAllBytes($bcf)
$bytes[0]=$bytes[0] -bxor 1;[IO.File]::WriteAllBytes($bcf,$bytes);[IO.File]::SetLastWriteTimeUtc($bcf,$mtime)
Invoke-CLI @('run','--config',$config)
Assert ((Read-Json "$work/state/convert.json").attempt -ne $second.attempt) 'Same-size/timestamp output corruption was reused'
$state=Read-Json "$work/state/stats.json"
Remove-Item -LiteralPath (Join-Path $state.result_dir 'samples.tsv')
Invoke-CLI @('run','--config',$config)
Assert ((Read-Json "$work/state/stats.json").attempt -ne $state.attempt) 'Missing declared output was reused'
$state=Read-Json "$work/state/stats.json"
$state.outputs.PSObject.Properties.Remove('samples.tsv');Save $state "$work/state/stats.json"
Invoke-CLI @('run','--config',$config)
Assert ((Read-Json "$work/state/stats.json").attempt -ne $state.attempt) 'Incomplete completion inventory was reused'
Push-Location $testRoot
try{Invoke-CLI @('run','--config',$config)}finally{Pop-Location}
Assert ((Read-Json "$work/last-run.json").reused_tasks -eq 2) 'Workflow depends on caller directory'

# Native test helper exposes deterministic failures; no shell interpolation or mocks.
function FailureConfig([string]$work) {
    @{schema_version=1;work_dir=$work;inputs=@{};tools=@{helper=@{path=$helper;version_args=@('--version')}};tasks=@(
        @{id='pipe';kind='command';memory_mb=128;commands=@(@{argv=@('helper','fail')},@{argv=@('helper','copy')});stdout='pipe.txt';outputs=@('pipe.txt')},
        @{id='after';kind='command';memory_mb=128;depends_on=@('pipe');commands=@(@{argv=@('helper','file','{out}/ok.txt','ok')});outputs=@('ok.txt')}
    )}
}
$f=FailureConfig "$testRoot/failure-work";$failureConfig="$testRoot/failure.json";Save $f $failureConfig
Invoke-CLI @('run','--config',$failureConfig) $true
Assert (!(Test-Path "$testRoot/failure-work/state/pipe.json") -and !(Test-Path "$testRoot/failure-work/state/after.json")) 'Failure published task completion'
$attempts=@(Get-ChildItem "$testRoot/failure-work/attempts/pipe" -Filter attempt.json -Recurse)
Assert ($attempts.Count -eq 1 -and (Read-Json $attempts[0].FullName).process.exit_codes[0] -eq 23) 'Upstream failure was hidden'
Assert ((Read-Json $attempts[0].FullName).process.exit_codes[1] -eq 0) 'Failure fixture did not leave successful downstream process'
$f.tasks[0].commands[0].argv=@('helper','emit','128');Save $f $failureConfig
Invoke-CLI @('run','--config',$failureConfig)
Assert ((Read-Json "$testRoot/failure-work/state/after.json").status -eq 'complete') 'Failed workflow could not resume'

# Tool identity changes invalidate cached work even when size and mtime are unchanged.
$toolcopy="$testRoot/helper copy.exe";Copy-Item $helper $toolcopy
$f.tools.helper.path=$toolcopy;Save $f $failureConfig;Invoke-CLI @('run','--config',$failureConfig)
$prior=Read-Json "$testRoot/failure-work/state/pipe.json"
$mtime=[IO.File]::GetLastWriteTimeUtc($toolcopy);$bytes=[IO.File]::ReadAllBytes($toolcopy)
# DOS stub message bytes are not executable code and can be changed safely for this test.
$bytes[100]=$bytes[100] -bxor 1;[IO.File]::WriteAllBytes($toolcopy,$bytes);[IO.File]::SetLastWriteTimeUtc($toolcopy,$mtime)
Invoke-CLI @('run','--config',$failureConfig)
Assert ((Read-Json "$testRoot/failure-work/state/pipe.json").attempt -ne $prior.attempt) 'Tool content change was reused'

$timeout=FailureConfig "$testRoot/timeout-work";$timeout.tasks=@(@{id='slow';kind='command';timeout_seconds=1;memory_mb=128;commands=@(@{argv=@('helper','spawn','{out}/child.pid')});outputs=@('child.pid')})
$timeoutConfig="$testRoot/timeout.json";Save $timeout $timeoutConfig;Invoke-CLI @('run','--config',$timeoutConfig) $true
Assert (!(Test-Path "$testRoot/timeout-work/state/slow.json")) 'Timed-out task was published'
$attempt=@(Get-ChildItem "$testRoot/timeout-work/attempts/slow" -Filter attempt.json -Recurse)[0]
Assert ((Read-Json $attempt.FullName).process.timed_out) 'Timeout not recorded'

# Killing the top-level runner must close its job and terminate the whole descendant tree.
$timeout.work_dir="$testRoot/interrupted-work";$timeout.tasks[0].timeout_seconds=60
$killConfig="$testRoot/interrupted.json";Save $timeout $killConfig
$running=Start-Process -FilePath $exe -ArgumentList @('run','--config',('"'+$killConfig+'"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput "$testRoot/interrupt-out.log" -RedirectStandardError "$testRoot/interrupt-err.log"
$deadline=[DateTime]::UtcNow.AddSeconds(30);$pidfile=$null
do {Start-Sleep -Milliseconds 100;$pidfile=Get-ChildItem "$testRoot/interrupted-work/attempts" -Filter child.pid -Recurse -ErrorAction SilentlyContinue|Select-Object -First 1} while(!$pidfile -and [DateTime]::UtcNow -lt $deadline -and !$running.HasExited)
Assert ($null -ne $pidfile) 'Interrupted workflow did not start its test child'
$descendant=[int][IO.File]::ReadAllText($pidfile.FullName)
$running.Kill();$running.WaitForExit();Start-Sleep -Milliseconds 500
Assert ($null -eq (Get-Process -Id $descendant -ErrorAction SilentlyContinue)) 'Descendant survived termination of workflow owner'
Assert (!(Test-Path "$testRoot/interrupted-work/state/slow.json")) 'Interrupted task was published'
$timeout.tasks[0].commands[0].argv=@('helper','file','{out}/child.pid','recovered');Save $timeout $killConfig
Invoke-CLI @('run','--config',$killConfig)
Assert ((Read-Json "$testRoot/interrupted-work/state/slow.json").status -eq 'complete') 'Interrupted workflow retained stale locks'

# Two heavy jobs must serialize while a bounded light job can overlap them.
$pools=@{schema_version=1;work_dir="$testRoot/pool-work";resources=@{threads=2;memory_mb=128;light_jobs=1};inputs=@{};tools=@{helper=@{path=$helper}};tasks=@()}
foreach($id in 'heavyone','heavytwo','lightone') {
    $pool=if($id -eq 'lightone'){'light'}else{'heavy'}
    $pools.tasks+=@{id=$id;kind='command';pool=$pool;memory_mb=64;commands=@(@{argv=@('helper','timed-file','1500','{out}/result.txt')});outputs=@('result.txt')}
}
$poolConfig="$testRoot/pools.json";Save $pools $poolConfig;Invoke-CLI @('run','--config',$poolConfig)
$h1=Read-Json "$testRoot/pool-work/state/heavyone.json";$h2=Read-Json "$testRoot/pool-work/state/heavytwo.json";$light=Read-Json "$testRoot/pool-work/state/lightone.json"
Assert ($h1.finished_unix_ms -le $h2.started_unix_ms -or $h2.finished_unix_ms -le $h1.started_unix_ms) 'Heavy tasks overlapped'
Assert ($light.started_unix_ms -lt [Math]::Max($h1.finished_unix_ms,$h2.finished_unix_ms) -and $light.finished_unix_ms -gt [Math]::Min($h1.started_unix_ms,$h2.started_unix_ms)) 'Light task did not execute concurrently'

foreach($case in 'cycle','unknown-input','undeclared-output','untracked-input','over-budget','unsafe-output','unknown-key') {
    $bad=Demo "$testRoot/invalid-$case"
    switch($case) {
        'cycle' {$bad.tasks[0].depends_on=@('stats')}
        'unknown-input' {$bad.tasks[1].input='{input:missing}'}
        'undeclared-output' {$bad.tasks[1].input='{task:convert}/absent.bcf'}
        'untracked-input' {$bad.tasks[1].input='../cohort.vcf'}
        'over-budget' {$bad.resources.threads=1}
        'unsafe-output' {$bad.tasks[0].outputs=@('../escape.bcf')}
        'unknown-key' {$bad.resources.threadz=2}
    }
    $path="$testRoot/invalid-$case.json";Save $bad $path;Invoke-CLI @('plan','--config',$path) $true
    Assert (!(Test-Path "$testRoot/invalid-$case/workflow.ninja")) 'Invalid plan published a graph'
}
Write-Host "Workflow integration checks passed; artifacts: $testRoot"
