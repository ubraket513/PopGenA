#!/usr/bin/env bash
# Raw paired FASTQ -> joint genotype workflow on the synthetic fixture: calls against
# independent truth, duplicate policy across runs/libraries, resume and strict input checks.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TEST_ROOT=$(new_test_root reads)
FIXTURE="$TEST_ROOT/input data"
WORK=$TEST_ROOT/work CONFIG=$TEST_ROOT/config.json
mkdir "$FIXTURE" && cp "$PROJECT"/tests/fixtures/reads/* "$FIXTURE/"

jq --arg fixture "$FIXTURE" --arg work "$WORK" '
    .reference = "\($fixture)/reference.fa" | .samples = "\($fixture)/samples.tsv" | .work_dir = $work
    | .runs |= map(.read1 = "\($fixture)/\(.id)_1.fastq" | .read2 = "\($fixture)/\(.id)_2.fastq")' \
    "$PROJECT/config/reads-demo.json" >"$CONFIG"

cli plan --config "$CONFIG"
check 'raw workflow incomplete' test "$(json "$WORK/plan.json" '.tasks | length')" = 40
check 'raw plan executed tools' test -z "$(ls -A "$WORK/attempts")"
cli run --config "$CONFIG"

GOLDEN=$'1000\t0/0:48\t0/1:24\t1/1:24\n2000\t0/1:48\t0/0:24\t./.:0\n3000\t1/1:48\t0/1:24\t0/0:24'
MASK=$(result_dir "$WORK" mask)/masked.bcf
check 'called GT/DP differs from independent FASTQ truth' test "$(bcf query -f '%POS[\t%GT:%DP]\n' "$MASK")" = "$GOLDEN"
check 'no-coverage sample was imputed as reference or CSI does not work' \
    test "$(bcf query -r 1:2000-2000 -s C -f '[%GT\t%DP]\n' "$MASK")" = $'./.\t0'
ALIGNMENTS=$(result_dir "$WORK" bams)/alignments.json
check 'run/library/sample identities were collapsed incorrectly' test "$(json "$ALIGNMENTS" '"\(.samples) \(.libraries | length)"')" = '3 4'
check 'cross-run duplicates in same library were not marked' test "$(json "$ALIGNMENTS" '.libraries[0] | "\(.duplicates) \(.usable_primary_records)"')" = '144 144'
check 'independent library was incorrectly deduplicated' test "$(json "$ALIGNMENTS" '.libraries[1] | "\(.duplicates) \(.usable_primary_records)"')" = '0 144'
for i in 1 2 3 4 5; do
    RAW=$(json "$(result_dir "$WORK" "r$i-check")/reads.json" .pairs)
    TRIM_DIR=$(result_dir "$WORK" "r$i-trim-check")
    TRIMMED=$(json "$TRIM_DIR/reads.json" .pairs)
    check 'fastp did not remove exactly the known low-quality pair' test "$RAW" = $(( TRIMMED + 1 ))
    check 'normalized fastp report count validation failed' test "$(json "$TRIM_DIR/fastp.json" \
        '"\(.summary.after_filtering.total_reads) \(.popgen_report_adapter.paired_counts_validated)"')" = "$(( 2 * TRIMMED )) true"
done
SAMPLES=$(result_dir "$WORK" stats)/samples.tsv
row() { awk -F'\t' -v row="$1" -v col="$2" 'NR==1{for(i=1;i<=NF;i++)h[$i]=i;next} NR==row+1{print $h[col]}' "$SAMPLES"; }
check 'raw calls lost sample identities' test "$(( $(wc -l <"$SAMPLES") - 1 ))" = 3
check 'raw-input diversity denominators differ from independent truth' \
    test "$(row 1 called) $(row 1 heterozygous) $(row 2 heterozygous) $(row 3 called) $(row 3 missing)" = '3 1 2 2 1'

CALL=$(state "$WORK" call attempt)
(cd "$TEST_ROOT" && cli run --config "$CONFIG")
check 'raw workflow did not resume unchanged' test "$(json "$WORK/last-run.json" .reused_tasks)" = 40
# An isolated masking change must reuse mapping and joint calling.
edit_json "$CONFIG" '.qc.min_dp = 25'
cli run --config "$CONFIG"
check 'mask threshold rebuilt alignment/calling' test "$(state "$WORK" call attempt)" = "$CALL"
check 'mask threshold invalidation was not limited to mask/stats' test "$(json "$WORK/last-run.json" .scheduled_tasks)" = 2
edit_json "$CONFIG" '.qc.min_dp = 5 | .processing.threads = 1'
cli run --config "$CONFIG"
MASK=$(result_dir "$WORK" mask)/masked.bcf
check 'one- and two-worker pipelines disagree' test "$(bcf query -f '%POS[\t%GT:%DP]\n' "$MASK")" = "$GOLDEN"

# A damaged final BCF is regenerated without rerunning raw-read tools.
TRIM=$(state "$WORK" r1-trim attempt)
flip_first_byte "$MASK"
cli run --config "$CONFIG"
check 'damaged BCF rerun reached unrelated read tools' \
    test "$(state "$WORK" r1-trim attempt) $(json "$WORK/last-run.json" .scheduled_tasks)" = "$TRIM 2"

# Configuration errors must be caught before commands are launched.
SAVED=$(cat "$CONFIG")
declare -A MUTATIONS=(
    [duplicate]='.runs[1].read1 = .runs[0].read1'
    [budget]='.limits.input_bytes = 1'
    [scratch]='.limits.scratch_bytes = 67108864'
    [zero-depth]='.qc.min_dp = 0'
    [unknown]='.processing.invented = 1'
)
for name in "${!MUTATIONS[@]}"; do
    jq "${MUTATIONS[$name]}" <<<"$SAVED" >"$TEST_ROOT/bad.json"
    cli --fail plan --config "$TEST_ROOT/bad.json"
done
# Wrong reference identity fails reference preparation, before mapping.
jq --arg work "$TEST_ROOT/wrong-reference" '.work_dir = $work | .reference_sha256 = ("0" * 64)' <<<"$SAVED" >"$TEST_ROOT/bad-reference.json"
cli --fail run --config "$TEST_ROOT/bad-reference.json"
check 'wrong reference published usable results' \
    test ! -e "$TEST_ROOT/wrong-reference/state/reference.json" -a ! -e "$TEST_ROOT/wrong-reference/state/r1-align.json"

# Strict paired FASTQ validation rejects malformed headers, mate name/count mismatches and truncation.
READ1=$FIXTURE/A_lane1_1.fastq READ2=$FIXTURE/A_lane1_2.fastq BAD=$TEST_ROOT/bad.fastq
sed 's#@A_lane1_1/1#@wrong/1#' "$READ1" >"$BAD";                  cli --fail raw-fastq --read1 "$BAD" --read2 "$READ2"
tail -c +2 "$READ1" >"$BAD";                                      cli --fail raw-fastq --read1 "$BAD" --read2 "$READ2"
{ cat "$READ1"; printf 'garbage\n'; } >"$BAD";                    cli --fail raw-fastq --read1 "$BAD" --read2 "$READ2"
head -c -10 "$READ1" >"$BAD";                                     cli --fail raw-fastq --read1 "$BAD" --read2 "$READ2"
sed 's#/1#/2#g' "$READ1" >"$BAD";                                 cli --fail raw-fastq --read1 "$BAD" --read2 "$READ2"
gzip -c "$READ1" >"$TEST_ROOT/full.fastq.gz"
truncate_tail "$TEST_ROOT/full.fastq.gz" "$TEST_ROOT/truncated.fastq.gz" 8
cli --fail raw-fastq --read1 "$TEST_ROOT/truncated.fastq.gz" --read2 "$READ2"
echo "FASTQ-to-genotype checks passed: $TEST_ROOT"
