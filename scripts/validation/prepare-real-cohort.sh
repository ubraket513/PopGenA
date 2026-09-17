#!/usr/bin/env bash
# Prepare the bounded real-data genotype validation: 200 individuals from the 1000 Genomes
# 2,504-person panel, chr21:15,000,000-16,000,000 from the NYGC 3,202-person phased release.
#
# Only index-derived byte ranges of the source VCF and one chromosome range of the original
# reference FASTA are fetched (scripts/sources/real-cohort.lock.json). Default is plan-only.
#   --download     fetch missing ranges (verified ranges in the cache are reused)
#   --reuse DIR    seed the cache from an earlier preparation directory; every chunk is
#                  re-verified, so this never trusts unverified bytes
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
export PATH="$ROOT/.deps/linux/prefix/bin:$PATH"
source "$ROOT/scripts/lib/fetch.sh"

LOCK=$ROOT/scripts/sources/real-cohort.lock.json
OUT=$ROOT/work/real-validation-linux DOWNLOAD=0 REUSE=
while (($#)); do
    case $1 in
    --out) OUT=$2; shift 2 ;;
    --download) DOWNLOAD=1; shift ;;
    --reuse) REUSE=$2; shift 2 ;;
    *) echo 'Usage: prepare-real-cohort.sh [--out DIR] [--download] [--reuse DIR]' >&2; exit 2 ;;
    esac
done
OUT=$(realpath -m -- "$OUT")
lock() { jq -r "$@" "$LOCK"; }
REGION=chr21:15000000-16000000

jq -e '[.files[], .metadata[] | .url | test("^https://ftp\\.1000genomes\\.ebi\\.ac\\.uk/[^?#@]*$")] | all' "$LOCK" >/dev/null ||
    die 'Unexpected validation source'
PLAN=$(jq --arg out "$OUT" '{download_bytes_upper_bound: 81000000, budget_bytes: .download_budget_bytes,
    scratch_bytes: .scratch_reservation_bytes, out: $out, selection,
    source_files_not_whole_downloads: (.files + .metadata),
    method: "Index-derived HTTP ranges plus original chromosome FASTA range; whole source VCF MD5 cannot be verified"}' "$LOCK")
if ((!DOWNLOAD)); then printf '%s\n' "$PLAN"; exit 0; fi

for tool in samtools bcftools; do command -v "$tool" >/dev/null || die "Missing $tool; run make first"; done
[[ -x $ROOT/build/region-ranges ]] || die 'Missing build/region-ranges; run make first'
mkdir -p -- "$OUT"
(($(stat -f -c '%a * %S' -- "$OUT") >= $(lock .scratch_reservation_bytes))) || die 'Insufficient free disk for validation reservation'
exec 9>"$OUT/prepare.lock"
flock -n 9 || die "Another preparation holds $OUT/prepare.lock"
cp -- "$LOCK" "$OUT/source-lock-used.json"
printf '%s\n' "$PLAN" >"$OUT/download-plan.json"
if [[ -n $REUSE ]]; then
    seed_chunks "$REUSE/region-chunks" "$OUT/region-chunks"
    seed_chunks "$REUSE/reference-chunks" "$OUT/reference-chunks"
    for name in chr21.vcf.gz.tbi original-panel.tsv; do
        [[ -e $OUT/$name || ! -f $REUSE/$name ]] || cp -- "$REUSE/$name" "$OUT/$name"
    done
fi

# ---- metadata and index -------------------------------------------------------------------
INDEX=$(lock '.files[] | select(.name == "chr21.vcf.gz.tbi")')
fetch_file "$OUT/chr21.vcf.gz.tbi" "$(jq -r .url <<<"$INDEX")" "$(jq -r .bytes <<<"$INDEX")"
[[ $(md5 "$OUT/chr21.vcf.gz.tbi") == "$(jq -r .md5 <<<"$INDEX")" ]] || die 'Index MD5 differs from release manifest'
PANEL=$(lock '.metadata[0]')
fetch_file "$OUT/original-panel.tsv" "$(jq -r .url <<<"$PANEL")" "$(jq -r .bytes <<<"$PANEL")"
[[ $(sha256 "$OUT/original-panel.tsv") == "$(jq -r .sha256 <<<"$PANEL")" ]] || die 'Original panel hash differs'

# ---- genotype byte ranges -----------------------------------------------------------------
SOURCE=$(lock '.files[] | select(.name == "chr21.vcf.gz")')
SOURCE_URL=$(jq -r .url <<<"$SOURCE") SOURCE_BYTES=$(jq -r .bytes <<<"$SOURCE")
INDEXED=$("$ROOT/build/region-ranges" "$OUT/chr21.vcf.gz.tbi" "$REGION") || die 'Cannot plan indexed ranges'
# Header block, index-selected BGZF chunks and the 28-byte EOF block.
REQUESTS=$(jq -r --argjson size "$SOURCE_BYTES" '([{start: 0, end: 524287}] + . + [{start: ($size - 28), end: ($size - 1)}])[]
    | if .start < 0 or .end >= $size or .end < .start then error("Invalid indexed byte range") else "\(.start) \(.end)" end' \
    <<<"$INDEXED" | split_ranges "$OUT/region-chunks" bgzf)
RANGE_BYTES=$(awk '{t += $2 - $1 + 1} END {printf "%.0f", t}' <<<"$REQUESTS")
((RANGE_BYTES <= 32000000)) || die 'Indexed genotype selection exceeds 32 MB byte budget'
fetch_ranges "$SOURCE_URL" "$SOURCE_BYTES" "$REQUESTS"
REQUESTS_JSON=$(awk '{printf "%s{\"start\":%s,\"end\":%s,\"bytes\":%s,\"path\":\"%s\"}", (NR>1?",":"["), $1, $2, $2-$1+1, $3} END {print "]"}' <<<"$REQUESTS")
REGION_PLAN=$(jq -n --arg source "$SOURCE_URL" --argjson bytes "$SOURCE_BYTES" --arg md5 "$(jq -r .md5 <<<"$SOURCE")" \
    --arg region "$REGION" --argjson range "$RANGE_BYTES" --argjson requests "$REQUESTS_JSON" \
    '{source: $source, source_bytes: $bytes, source_full_md5_not_verified: $md5, region: $region, range_bytes: $range,
      reference_bytes: 47377268, requests: $requests, scope: "Partial byte cache, not a complete source VCF"}')
printf '%s\n' "$REGION_PLAN" >"$OUT/region-plan.json"

# A sparse file with every fetched range at its original offset; only indexed regions are readable.
VCF=$OUT/chr21.region-cache.vcf.gz
rm -f -- "$VCF"
truncate -s "$SOURCE_BYTES" -- "$VCF"
while read -r start _ path; do
    dd if="$path" of="$VCF" bs=1M seek="$start" oflag=seek_bytes conv=notrunc status=none
done <<<"$REQUESTS"
cp -- "$OUT/chr21.vcf.gz.tbi" "$VCF.tbi"
touch -- "$VCF.tbi"
HASHES=$(while read -r start end path; do printf '{"start":%s,"end":%s,"sha256":"%s"}\n' "$start" "$end" "$(sha256 "$path")"; done <<<"$REQUESTS" | jq -s .)
jq --argjson hashes "$HASHES" '. + {downloaded_range_sha256: $hashes}' <<<"$REGION_PLAN" >"$OUT/region-provenance.json"

# ---- reference chromosome range -------------------------------------------------------------
REFERENCE=$(lock '.files[] | select(.name == "chr21.sequence.txt") | .name = "chr21"')
FASTA=$OUT/chr21.fa
fetch_reference_contig "$REFERENCE" "$FASTA" "$OUT/reference-chunks"
jq -n --argjson ref "$REFERENCE" --arg sha "$(sha256 "$FASTA")" '{source: $ref.url, start: $ref.range_start,
    bytes: (($ref.bases - 1) / $ref.line_bases | floor) * $ref.line_bytes + (($ref.bases - 1) % $ref.line_bases) + 1,
    sequence_md5: $ref.sequence_md5, fasta_sha256: $sha,
    rejected_alternative: "UCSC hg38 chr21 sequence MD5 differs; not used"}' >"$OUT/reference-provenance.json"

# ---- selection, subset and workflow configuration ------------------------------------------
PANEL_ROWS=$(tail -n +2 "$OUT/original-panel.tsv" | tr -d '\r' | awk -F'\t' 'NF >= 3')
[[ $(wc -l <<<"$PANEL_ROWS") == 2504 && $(cut -f1 <<<"$PANEL_ROWS" | sort -u | wc -l) == 2504 ]] ||
    die 'Original panel identity/count changed'
SELECTED=$(for pop in AFR AMR EAS EUR SAS; do awk -F'\t' -v p="$pop" '$3 == p' <<<"$PANEL_ROWS" | LC_ALL=C sort -t$'\t' -k1,1 | head -40; done)
[[ $(wc -l <<<"$SELECTED") == 200 ]] || die 'Expected 200 selected individuals'
cut -f1 <<<"$SELECTED" >"$OUT/selected.txt"
{ printf 'sample\tpopulation\n'; cut -f1,2 <<<"$SELECTED"; } >"$OUT/samples.tsv"
{ printf 'sample\tpopulation\tsuperpopulation\n'; cut -f1-3 <<<"$SELECTED"; } >"$OUT/selection.tsv"

samtools faidx "$FASTA"
BCF=$OUT/cohort.bcf
bcftools view -r "$REGION" -S "$OUT/selected.txt" -m2 -M2 -v snps -f PASS -Ob -o "$BCF" "$VCF"
bcftools index -f "$BCF"
COUNT=$(bcftools index -n "$BCF" 2>/dev/null)
((COUNT >= 10000 && COUNT <= 50000)) || die "Subset outside planned 10k-50k SNP validation size: $COUNT"

jq -n --arg out "$OUT" '{schema_version: 1, workflow_type: "genotypes", work_dir: "\($out)/analysis",
    assembly: "GRCh38 chr21; NYGC 20201028 phased release",
    input: "\($out)/cohort.bcf", reference: "\($out)/chr21.fa", reference_index: "\($out)/chr21.fa.fai", samples: "\($out)/samples.tsv",
    resources: {threads: 8, memory_mb: 6144}, qc: {min_dp: 0, min_gq: 0, sample_missing: 0.1, variant_missing: 0.1},
    analysis: {pcs: 5, pca_maf: 0.05, kinship_maf: 0.05, kinship_threshold: 0.0884, relatedness_policy: "retain",
               ld_window: 50, ld_step: 5, ld_r2: 0.2, threads: 2, memory_mb: 1152}}' >"$OUT/config.json"
jq -n --arg lock "$(sha256 "$LOCK")" --arg prepared "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson sites "$COUNT" \
    --arg reference "$(sha256 "$FASTA")" --arg input "$(sha256 "$BCF")" --arg selection "$(lock .selection)" \
    '{source_lock_sha256: $lock, prepared_utc: $prepared, samples: 200, sites: $sites, reference_sha256: $reference,
      input_sha256: $input, selection: $selection,
      quality_policy: "Phased release GT only; DP/GQ filters explicitly disabled, not synthesized",
      acquisition: "Indexed byte ranges: index MD5 verified, source whole-file MD5 not verified; per-range SHA256 recorded",
      scope: "Single-region integration check; not genome-wide relatedness or population inference"}' >"$OUT/prepared.json"
echo "Prepared real-data genotype validation: $OUT/config.json"
