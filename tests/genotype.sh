#!/usr/bin/env bash
# Genotype QC/PCA workflow on the deterministic synthetic fixture: 15-task DAG,
# independent expectations, PCA eigenpair validation, resume and invalidation.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TEST_ROOT=$(new_test_root genotype)
FIXTURE=$PROJECT/tests/fixtures/genotype
WORK=$TEST_ROOT/work CONFIG=$TEST_ROOT/config.json

jq --arg fixture "$FIXTURE" --arg work "$WORK" '
    .input = "\($fixture)/cohort.vcf" | .reference = "\($fixture)/reference.fa"
    | .reference_index = "\($fixture)/reference.fa.fai" | .samples = "\($fixture)/samples.tsv"
    | .work_dir = $work' "$PROJECT/config/genotype-demo.json" >"$CONFIG"

cli plan --config "$CONFIG"
check 'genotype plan executed tasks' test -z "$(ls -A "$WORK/state")"
check 'incomplete genotype DAG' test "$(json "$WORK/plan.json" '.tasks | length')" = 15
cli run --config "$CONFIG"

MASK=$(result_dir "$WORK" mask)/mask.json
check 'mask record/sample totals wrong' test "$(json "$MASK" '"\(.records) \(.kept) \(.sample_count)"')" = "$(json "$FIXTURE/expected.json" .input_records) 240 64"
check 'mask skipped categories wrong' test "$(json "$MASK" '.skipped | "\(.non_autosomal) \(.not_biallelic_snp) \(.site_filter)"')" = '1 1 1'
SELECTION=$(result_dir "$WORK" select)/selection.json
check 'sample missingness exclusions wrong' test "$(json "$SELECTION" '.sample_qc_excluded | join(",")')" = 'S62,S63'
check 'duplicate relatedness exclusion wrong' test "$(json "$SELECTION" \
    '"\(.retained | length) \(.relatedness_excluded | length) \(.retained | index("S00") != null) \(.retained | index("S61") == null)"')" = '61 1 true true'

STATS=$(result_dir "$WORK" stats)
check 'variant missingness filtering wrong' test "$(( $(wc -l <"$STATS/sites.tsv") - 1 ))" = 238
pos_count() { awk -F'\t' -v p="$1" 'NR==1{for(i=1;i<=NF;i++)if($i=="pos")c=i;next} $c==p' "$STATS/sites.tsv" | wc -l; }
check 'diversity data lost monomorphic/singleton sites' test "$(pos_count 15) $(pos_count 20)" = '1 1'
check 'BCF/statistics sample set differs' test "$(( $(wc -l <"$STATS/samples.tsv") - 1 ))" = "$(json "$SELECTION" '.retained | length')"

MARKERS=$(result_dir "$WORK" prune)/data.prune.in
check 'PCA MAF filter not applied' bash -c "! grep -qxE '1:15:A:C|1:20:A:C' '$MARKERS'"
MARKER_COUNT=$(wc -l <"$MARKERS")
check 'LD pruning did not remove duplicated loci or removed all markers' test "$MARKER_COUNT" -lt 236 -a "$MARKER_COUNT" -gt 3
VALIDATION=$(result_dir "$WORK" validate)/validation.json
check 'independent PCA verification absent' test "$(json "$VALIDATION" '"\(.validated) \(.markers) \(.relative_eigenpair_residual | length)"')" = "true $MARKER_COUNT 3"
check 'PCA covariance residual exceeds tolerance' test "$(json "$VALIDATION" '[.relative_eigenpair_residual[] | select(. >= 0.001)] | length')" = 0

MASKED=$(result_dir "$WORK" mask)/masked.bcf
for case in '25 S02 ./.' '30 S03 ./.' '35 S04 ./.' '40 S05 ./.' '45 S06 0/1'; do
    read -r pos sample expected <<<"$case"
    check "masked genotype wrong: $sample/$pos" test "$(bcf query -r "1:$pos-$pos" -s "$sample" -f '[%GT]\n' "$MASKED")" = "$expected"
done
FINAL=$(result_dir "$WORK" bcf)/cohort.bcf
check 'published CSI is unusable' test "$(bcf query -r 1:15-20 -f '%POS\n' "$FINAL" | wc -l)" = 2

ATTEMPT=$(state "$WORK" pca attempt)
(cd "$TEST_ROOT" && cli run --config "$CONFIG")
check 'unchanged genotype run did not fully resume' test "$(json "$WORK/last-run.json" .reused_tasks)" = 15
check 'PCA rebuilt on unchanged run' test "$(state "$WORK" pca attempt)" = "$ATTEMPT"

# Eigenvector signs are arbitrary: independently verified eigenpairs must accept sign flips.
PCA=$(result_dir "$WORK" pca) PSAM=$(result_dir "$WORK" retained)/data.psam FLIPPED=$TEST_ROOT/flipped.eigenvec
awk 'BEGIN{OFS="\t"} NR==1{print;next} {for(i=3;i<=NF;i++)$i=sprintf("%.17g",-$i); $1=$1; print}' "$PCA/data.eigenvec" >"$FLIPPED"
cli pca-check --psam "$PSAM" --pcs 3 --vectors "$FLIPPED" --values "$PCA/data.eigenval" --bcf "$FINAL" --markers "$MARKERS"
printf '100\n99\n98\n' >"$TEST_ROOT/bad.eigenval"
cli --fail pca-check --psam "$PSAM" --pcs 3 --vectors "$FLIPPED" --values "$TEST_ROOT/bad.eigenval" --bcf "$FINAL" --markers "$MARKERS"
check 'incorrect eigenvalue test failed for an unrelated reason' grep -q 'eigenpair differs' "$TEST_ROOT/stderr.txt"

# Output damage reruns downstream tasks, preserving independent upstream generations.
IMPORT=$(state "$WORK" import attempt)
echo corrupted >>"$PCA/data.eigenvec"
cli run --config "$CONFIG"
check 'corrupted PCA output reused' test "$(state "$WORK" pca attempt)" != "$ATTEMPT"
check 'PCA damage rebuilt unrelated import' test "$(state "$WORK" import attempt)" = "$IMPORT"

# Explicit retain policy keeps the duplicate; upstream QC is reused.
edit_json "$CONFIG" '.analysis.relatedness_policy = "retain"'
cli run --config "$CONFIG"
KEPT=$(result_dir "$WORK" select)/selection.json
check 'explicit retain policy ignored' test "$(json "$KEPT" '"\(.retained | length) \(.relatedness_excluded | length) \(.reported_pairs > 0)"')" = '62 0 true'
check 'policy change rebuilt import' test "$(state "$WORK" import attempt)" = "$IMPORT"

# Small LD windows get a usable default step rather than failing later in PLINK.
edit_json "$CONFIG" '.analysis.ld_window = 2 | del(.analysis.ld_step)'
cli run --config "$CONFIG"
check 'LD-only change rebuilt import' test "$(state "$WORK" import attempt)" = "$IMPORT"

# Settings that must fail during planning: below PLINK's minimum workspace, unknown
# key, omitted relatedness policy.
SAVED=$(cat "$CONFIG")
jq '.analysis.memory_mb = 1024' <<<"$SAVED" >"$CONFIG"; cli --fail plan --config "$CONFIG"
jq '.analysis.invented = 1' <<<"$SAVED" >"$CONFIG"; cli --fail plan --config "$CONFIG"
jq 'del(.analysis.relatedness_policy)' <<<"$SAVED" >"$CONFIG"; cli --fail plan --config "$CONFIG"

# A failed repeated mask invocation must never truncate existing products.
BEFORE=$(stat -c %s "$MASKED")
cli --fail mask --input "$(result_dir "$WORK" normalize)/normalized.bcf" --out "$MASKED"
check 'mask overwrote an existing product' test "$(stat -c %s "$MASKED")" = "$BEFORE"
echo "Genotype QC/PCA integration checks passed: $TEST_ROOT"
