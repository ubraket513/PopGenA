#!/usr/bin/env bash
# Synthetic streaming-statistics benchmark: generate SAMPLES x SITES hard calls with
# build/benchmark-fixture, run the statistics workflow, and check every aggregate count.
# Measures streaming statistics only; it makes no KING/PCA scalability claim.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
export PATH="$ROOT/.deps/linux/prefix/bin:$PATH" # vendored tools (jq, bcftools, ...) first
SAMPLES=1000 SITES=1000 OUT=''
while (( $# )); do
    case $1 in
        --samples) SAMPLES=$2; shift 2 ;;
        --sites) SITES=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        *) echo 'Usage: benchmark.sh [--samples 1..100000] [--sites 1..10000] [--out DIR]' >&2; exit 2 ;;
    esac
done
die() { echo "Error: $*" >&2; exit 1; }
[[ $SAMPLES =~ ^[0-9]+$ ]] && (( SAMPLES >= 1 && SAMPLES <= 100000 )) || die 'samples must be 1..100000'
[[ $SITES =~ ^[0-9]+$ ]] && (( SITES >= 1 && SITES <= 10000 )) || die 'sites must be 1..10000'
OUT=$(realpath -m -- "${OUT:-$ROOT/work/benchmark-linux-$SAMPLES-$SITES}")
FIXTURE=$ROOT/build/benchmark-fixture
[[ -x $FIXTURE && -x $ROOT/build/popgen ]] || die 'Run make first (build/popgen, build/benchmark-fixture)'
mkdir -p -- "$OUT"

jq -n --arg work "$OUT/workflow" --arg fixture "$FIXTURE" --arg samples "$SAMPLES" --arg sites "$SITES" '{
    schema_version: 1, work_dir: $work, inputs: {}, resources: {threads: 4, memory_mb: 4096},
    tools: {fixture: {path: $fixture, version_args: ["--version"]}},
    tasks: [
        {id: "generate", kind: "command", pool: "heavy", memory_mb: 2048, timeout_seconds: 1800,
         commands: [{argv: ["fixture", $samples, $sites, "{out}/cohort.bcf"], threads: 1}],
         outputs: ["cohort.bcf", "expected.json"], stdout: "expected.json"},
        {id: "stats", kind: "stats", depends_on: ["generate"], input: "{task:generate}/cohort.bcf",
         memory_mb: 2048, timeout_seconds: 1800, hts_threads: 2}
    ]}' >"$OUT/config.json"
"$ROOT/build/popgen" run --config "$OUT/config.json" >/dev/null || die 'Benchmark workflow failed'

STATE=$OUT/workflow/state
TRUTH=$(jq -r .result_dir "$STATE/generate.json")/expected.json
ROWS=$(jq -r .result_dir "$STATE/stats.json")/samples.tsv
(( $(wc -l <"$ROWS") - 1 == SAMPLES )) || die 'Benchmark sample count differs'
SUMS=$(awk -F'\t' 'NR == 1 {for (i = 1; i <= NF; i++) h[$i] = i; next}
    {c += $h["called"]; het += $h["heterozygous"]; alt += $h["alt_alleles"]; m += $h["missing"]}
    END {printf "%.0f %.0f %.0f %.0f", c, het, alt, m}' "$ROWS")
[[ $SUMS == "$(jq -r '"\(.called) \(.heterozygous) \(.alternate_alleles) \(.missing)"' "$TRUTH")" ]] \
    || die "Benchmark count mismatch: $SUMS"

jq -n --argjson samples "$SAMPLES" --argjson sites "$SITES" --slurpfile truth "$TRUTH" \
    --slurpfile generate "$STATE/generate.json" --slurpfile stats "$STATE/stats.json" \
    --argjson bytes "$(du -sb -- "$OUT/workflow" | cut -f1)" \
    '{samples: $samples, sites: $sites, genotypes: ($samples * $sites), checked_counts: $truth[0],
      generate: $generate[0].process, stats: $stats[0].process, retained_work_bytes: $bytes,
      memory_metric: "Peak RSS of the largest process (getrusage)",
      scope: "Streaming statistics only; no KING/PCA scalability claim"}' >"$OUT/benchmark.json"
echo "Verified benchmark report: $OUT/benchmark.json"
