#!/usr/bin/env bash
# Check a completed real-data genotype workflow against independent bcftools per-sample
# counts and its PCA validation, and write report[-ANALYSIS].json plus a resources CSV.
set -euo pipefail
export PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/.deps/linux/prefix/bin:$PATH" # vendored jq first

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
OUT=$ROOT/work/real-validation-linux ANALYSIS=analysis
while (( $# )); do
    case $1 in
        --out) OUT=$2; shift 2 ;;
        --analysis) ANALYSIS=$2; shift 2 ;;
        *) echo 'Usage: report-real-validation.sh [--out DIR] [--analysis NAME]' >&2; exit 2 ;;
    esac
done
die() { echo "Error: $*" >&2; exit 1; }
[[ $ANALYSIS =~ ^[A-Za-z0-9_-]+$ ]] || die 'Invalid analysis name'
WORKFLOW=$OUT/$ANALYSIS
shopt -s nullglob
STATES=("$WORKFLOW"/state/*.json)
(( ${#STATES[@]} == 15 )) || die 'Expected 15 completed genotype workflow states'
jq -se 'all(.status == "complete")' "${STATES[@]}" >/dev/null || die 'Incomplete workflow state'
result() { jq -r .result_dir "$WORKFLOW/state/$1.json"; }

INDEPENDENT=$OUT/independent-bcftools-stats${ANALYSIS/#analysis/}.txt
"$ROOT/.deps/linux/prefix/bin/bcftools" stats -s - "$(result bcf)/cohort.bcf" >"$INDEPENDENT" || die 'Independent bcftools stats failed'
# PSC columns: 3 sample, 4 nRefHom, 5 nNonRefHom, 6 nHets, 14 nMissing.
EXPECTED=$(awk -F'\t' '$1 == "PSC" {print $3 "\t" ($4 + $5 + $6) "\t" $6 "\t" (2 * $5 + $6) "\t" $14}' "$INDEPENDENT" | LC_ALL=C sort)
ACTUAL=$(awk -F'\t' 'NR == 1 {for (i = 1; i <= NF; i++) h[$i] = i; next}
    {print $h["sample"] "\t" $h["called"] "\t" $h["heterozygous"] "\t" $h["alt_alleles"] "\t" $h["missing"]}' \
    "$(result stats)/samples.tsv" | LC_ALL=C sort)
[[ -n $ACTUAL && $ACTUAL == "$EXPECTED" ]] || die 'Independent per-sample called/heterozygous/alt/missing counts differ'
VALIDATION=$(result validate)/validation.json
jq -e .validated "$VALIDATION" >/dev/null || die 'PCA validation did not succeed'

TASKS=$(jq -s 'map({task, elapsed_ms: .process.elapsed_ms, max_rss_bytes: .process.max_rss_bytes,
    cpu_user_ms: .process.cpu_user_ms, cpu_system_ms: .process.cpu_system_ms}) | sort_by(.task)' "${STATES[@]}")
jq -e 'all(.max_rss_bytes != null)' <<<"$TASKS" >/dev/null || die 'Task predates Linux resource accounting'
SUFFIX=${ANALYSIS/#analysis/}
jq -n --slurpfile prepared "$OUT/prepared.json" --slurpfile pca "$VALIDATION" --slurpfile last "$WORKFLOW/last-run.json" \
    --argjson tasks "$TASKS" --argjson samples "$(wc -l <<<"$ACTUAL")" --argjson bytes "$(du -sb -- "$WORKFLOW" | cut -f1)" \
    '{prepared: $prepared[0], retained_samples: $samples, independent_sample_counts_match: true,
      independent_fields: ["called", "heterozygous", "alt_alleles", "missing"], pca: $pca[0], tasks: $tasks,
      last_run: $last[0], retained_analysis_bytes: $bytes,
      memory_metric: "Peak RSS of the largest process per task (getrusage), not the sum across a pipeline",
      scope: "Single chromosome interval integration only; not population structure or whole-genome accuracy"}' \
    >"$OUT/report$SUFFIX.json"
jq -r '(.[0] | keys_unsorted | @csv), (.[] | [.[]] | @csv)' <<<"$TASKS" >"$OUT/resources$SUFFIX.csv"
echo "Independent counts and PCA validated: $OUT/report$SUFFIX.json"
