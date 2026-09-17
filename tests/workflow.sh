#!/usr/bin/env bash
# Workflow engine: planning, resume/invalidation, failure isolation, timeouts, runner
# termination, pool scheduling and configuration validation.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TEST_ROOT=$(new_test_root workflow)

# demo <work_dir>: the two-task convert (pipeline) -> stats workflow as JSON.
demo() {
    jq -n --arg work "$1" --arg cohort "$TEST_ROOT/cohort.vcf" --arg samples "$PROJECT/tests/fixtures/samples.tsv" --arg bcftools "$BCFTOOLS" '{
        schema_version: 1, work_dir: $work, resources: {threads: 8, memory_mb: 4096, light_jobs: 1},
        inputs: {cohort: $cohort, samples: $samples},
        tools: {bcftools: {path: $bcftools, version_args: ["--version"]}},
        tasks: [
            {id: "convert", kind: "command", pool: "heavy", memory_mb: 512, commands: [
                {argv: ["bcftools", "view", "-Ou", "{input:cohort}"], threads: 1},
                {argv: ["bcftools", "view", "-Ob", "-o", "{out}/cohort.bcf", "-"], threads: 1}],
             outputs: ["cohort.bcf"]},
            {id: "stats", kind: "stats", depends_on: ["convert"], input: "{task:convert}/cohort.bcf",
             samples: "{input:samples}", hts_threads: 1, min_dp: 0, memory_mb: 512}
        ]}'
}

cp "$PROJECT/tests/fixtures/cohort.vcf" "$TEST_ROOT/cohort.vcf"
CONFIG=$TEST_ROOT/demo.json WORK=$TEST_ROOT/work
demo "$WORK" >"$CONFIG"
cli plan --config "$CONFIG"
check 'planning created a completion record' test -z "$(ls -A "$WORK/state")"
check 'planning launched a task/probe' test -z "$(ls -A "$WORK/attempts")"
cli run --config "$CONFIG"
FIRST=$(state "$WORK" convert attempt) STATS=$(state "$WORK" stats attempt)
check 'workflow output differs from independent golden' cmp -s "$(result_dir "$WORK" stats)/samples.tsv" "$PROJECT/tests/golden/samples.tsv"
check 'pipeline process statuses missing' test "$(state "$WORK" convert 'process.exit_codes | join(",")')" = '0,0'
check 'tool version was not recorded' grep -q 'bcftools 1.24' <<<"$(state "$WORK" convert tool_versions.bcftools.stdout)"

cli run --config "$CONFIG"
check 'unchanged workflow did not reuse outputs' test "$(json "$WORK/last-run.json" '"\(.reused_tasks) \(.scheduled_tasks)"')" = '2 0'
check 'unchanged result was rebuilt' test "$(state "$WORK" stats attempt)" = "$STATS"

edit_json "$CONFIG" '.tasks[1].min_dp = 10'
cli run --config "$CONFIG"
check 'downstream-only config change rebuilt upstream task' test "$(state "$WORK" convert attempt)" = "$FIRST"
check 'config change did not invalidate task' test "$(state "$WORK" stats attempt)" != "$STATS"

sed -i 's/^##fileformat=VCFv4.3/&\n##source=changed/' "$TEST_ROOT/cohort.vcf"
cli run --config "$CONFIG"
SECOND=$(state "$WORK" convert attempt)
check 'changed input was reused' test "$SECOND" != "$FIRST"
flip_first_byte "$(result_dir "$WORK" convert)/cohort.bcf"
cli run --config "$CONFIG"
check 'same-size/timestamp output corruption was reused' test "$(state "$WORK" convert attempt)" != "$SECOND"

PRIOR=$(state "$WORK" stats attempt)
rm "$(result_dir "$WORK" stats)/samples.tsv"
cli run --config "$CONFIG"
check 'missing declared output was reused' test "$(state "$WORK" stats attempt)" != "$PRIOR"
PRIOR=$(state "$WORK" stats attempt)
edit_json "$WORK/state/stats.json" 'del(.outputs["samples.tsv"])'
cli run --config "$CONFIG"
check 'incomplete completion inventory was reused' test "$(state "$WORK" stats attempt)" != "$PRIOR"
(cd "$TEST_ROOT" && cli run --config "$CONFIG")
check 'workflow depends on caller directory' test "$(json "$WORK/last-run.json" .reused_tasks)" = 2

# The native helper provides deterministic failures; no shell interpolation or mocks.
failure_config() {
    jq -n --arg work "$1" --arg helper "${2:-$HELPER}" '{
        schema_version: 1, work_dir: $work, inputs: {}, tools: {helper: {path: $helper, version_args: ["--version"]}},
        tasks: [
            {id: "pipe", kind: "command", memory_mb: 128, commands: [{argv: ["helper", "fail"]}, {argv: ["helper", "copy"]}],
             stdout: "pipe.txt", outputs: ["pipe.txt"]},
            {id: "after", kind: "command", memory_mb: 128, depends_on: ["pipe"],
             commands: [{argv: ["helper", "file", "{out}/ok.txt", "ok"]}], outputs: ["ok.txt"]}
        ]}'
}
F=$TEST_ROOT/failure.json FW=$TEST_ROOT/failure-work
failure_config "$FW" >"$F"
cli --fail run --config "$F"
check 'failure published task completion' test ! -e "$FW/state/pipe.json" -a ! -e "$FW/state/after.json"
ATTEMPT=$(find "$FW/attempts/pipe" -name attempt.json)
check 'upstream failure was hidden' test "$(json "$ATTEMPT" '.process.exit_codes | join(",")')" = '23,0'
edit_json "$F" '.tasks[0].commands[0].argv = ["helper", "emit", "128"]'
cli run --config "$F"
check 'failed workflow could not resume' test "$(state "$FW" after status)" = complete

# Tool content changes invalidate cached work even with unchanged size and mtime.
TOOLCOPY="$TEST_ROOT/helper copy"
cp -p "$HELPER" "$TOOLCOPY"
edit_json "$F" --arg tool "$TOOLCOPY" '.tools.helper.path = $tool'
cli run --config "$F"
PRIOR=$(state "$FW" pipe attempt)
# Append-safe corruption: flip a byte in the ELF section header string padding at the end.
STAMP=$(stat -c %y "$TOOLCOPY") SIZE=$(stat -c %s "$TOOLCOPY")
printf '\x01' | dd of="$TOOLCOPY" bs=1 seek=$(( SIZE - 1 )) count=1 conv=notrunc status=none
touch -d "$STAMP" "$TOOLCOPY"
cli run --config "$F"
check 'tool content change was reused' test "$(state "$FW" pipe attempt)" != "$PRIOR"

T=$TEST_ROOT/timeout.json
failure_config "$TEST_ROOT/timeout-work" | jq '.tasks = [{id: "slow", kind: "command", timeout_seconds: 1, memory_mb: 128,
    commands: [{argv: ["helper", "spawn", "{out}/child.pid"]}], outputs: ["child.pid"]}]' >"$T"
cli --fail run --config "$T"
check 'timed-out task was published' test ! -e "$TEST_ROOT/timeout-work/state/slow.json"
check 'timeout not recorded' test "$(json "$(find "$TEST_ROOT/timeout-work/attempts/slow" -name attempt.json | head -1)" .process.timed_out)" = true

# SIGKILL of the top-level runner must still terminate every descendant (parent-death
# signals: runner -> ninja -> popgen step -> tool process group).
K=$TEST_ROOT/interrupted.json KW=$TEST_ROOT/interrupted-work
jq --arg work "$KW" '.work_dir = $work | .tasks[0].timeout_seconds = 60' "$T" >"$K"
"$POPGEN" run --config "$K" >"$TEST_ROOT/interrupt-out.log" 2>"$TEST_ROOT/interrupt-err.log" &
RUNNER=$!
PIDFILE=
for _ in $(seq 300); do
    PIDFILE=$(find "$KW/attempts" -name child.pid 2>/dev/null | head -1 || true)
    [[ -n $PIDFILE && -s $PIDFILE ]] && break
    sleep 0.1
done
check 'interrupted workflow did not start its test child' test -s "$PIDFILE"
DESCENDANT=$(cat "$PIDFILE")
kill -KILL "$RUNNER"; wait "$RUNNER" 2>/dev/null || true
alive() { [[ -e /proc/$1 ]] && ! grep -q '^State:.*Z' "/proc/$1/status" 2>/dev/null; }
for _ in $(seq 50); do alive "$DESCENDANT" || break; sleep 0.1; done
check 'descendant survived termination of workflow owner' bash -c "! [[ -e /proc/$DESCENDANT ]] || grep -q '^State:.*Z' /proc/$DESCENDANT/status"
check 'interrupted task was published' test ! -e "$KW/state/slow.json"
edit_json "$K" '.tasks[0].commands[0].argv = ["helper", "file", "{out}/child.pid", "recovered"]'
cli run --config "$K"
check 'interrupted workflow retained stale locks' test "$(state "$KW" slow status)" = complete

# Two heavy jobs serialize while one light job may overlap them.
POOLS=$TEST_ROOT/pools.json PW=$TEST_ROOT/pool-work
jq -n --arg work "$PW" --arg helper "$HELPER" '{
    schema_version: 1, work_dir: $work, resources: {threads: 2, memory_mb: 128, light_jobs: 1}, inputs: {},
    tools: {helper: {path: $helper}},
    tasks: [["heavyone", "heavy"], ["heavytwo", "heavy"], ["lightone", "light"]] | map({
        id: .[0], kind: "command", pool: .[1], memory_mb: 64,
        commands: [{argv: ["helper", "timed-file", "1500", "{out}/result.txt"]}], outputs: ["result.txt"]})}' >"$POOLS"
cli run --config "$POOLS"
read -r H1S H1F <<<"$(json "$PW/state/heavyone.json" '"\(.started_unix_ms) \(.finished_unix_ms)"')"
read -r H2S H2F <<<"$(json "$PW/state/heavytwo.json" '"\(.started_unix_ms) \(.finished_unix_ms)"')"
read -r LS LF <<<"$(json "$PW/state/lightone.json" '"\(.started_unix_ms) \(.finished_unix_ms)"')"
check 'heavy tasks overlapped' test $(( H1F <= H2S || H2F <= H1S )) = 1
check 'light task did not execute concurrently' test $(( LS < (H1F > H2F ? H1F : H2F) && LF > (H1S < H2S ? H1S : H2S) )) = 1

# A top-level runner outlives the shell that launched it (nohup-style background use).
DETACHED=$TEST_ROOT/detached.json DW=$TEST_ROOT/detached-work
jq --arg work "$DW" '.work_dir = $work | .tasks = [.tasks[0] | .id = "slow" | .pool = "heavy"]' "$POOLS" >"$DETACHED"
bash -c '"$1" run --config "$2" >"$3/detached.log" 2>&1 &' _ "$POPGEN" "$DETACHED" "$TEST_ROOT"
for _ in $(seq 150); do [[ -s $DW/state/slow.json ]] && break; sleep 0.1; done
check 'runner was terminated when its launching shell exited' test "$(state "$DW" slow status 2>/dev/null)" = complete

declare -A MUTATIONS=(
    [cycle]='.tasks[0].depends_on = ["stats"]'
    [unknown-input]='.tasks[1].input = "{input:missing}"'
    [undeclared-output]='.tasks[1].input = "{task:convert}/absent.bcf"'
    [untracked-input]='.tasks[1].input = "../cohort.vcf"'
    [over-budget]='.resources.threads = 1'
    [unsafe-output]='.tasks[0].outputs = ["../escape.bcf"]'
    [unknown-key]='.resources.threadz = 2'
)
for name in "${!MUTATIONS[@]}"; do
    demo "$TEST_ROOT/invalid-$name" | jq "${MUTATIONS[$name]}" >"$TEST_ROOT/invalid-$name.json"
    cli --fail plan --config "$TEST_ROOT/invalid-$name.json"
    check "invalid plan ($name) published a graph" test ! -e "$TEST_ROOT/invalid-$name/workflow.ninja"
done
echo "Workflow integration checks passed; artifacts: $TEST_ROOT"
