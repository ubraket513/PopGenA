#!/usr/bin/env bash
# Prepare the bounded real-read accuracy check described in scripts/sources/giab-hg002.lock.json:
# HG002 read pairs for one GRCh38 interval, the chr20 reference, the GIAB benchmark and a
# reads workflow configuration. Default is plan-only; --download fetches.
#
# Reads come from byte ranges of the indexed GIAB BAM, so only pairs whose mates both
# overlap the interval are kept. This selection depends on the original alignment
# (reference/selection bias) and is disclosed in prepared.json.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
export PATH="$ROOT/.deps/linux/prefix/bin:$PATH"
source "$ROOT/scripts/lib/fetch.sh"

LOCK=$ROOT/scripts/sources/giab-hg002.lock.json
OUT=$ROOT/work/giab-hg002 DOWNLOAD=0
while (($#)); do
    case $1 in
    --out) OUT=$2; shift 2 ;;
    --download) DOWNLOAD=1; shift ;;
    *) echo 'Usage: prepare-giab-reads.sh [--out DIR] [--download]' >&2; exit 2 ;;
    esac
done
OUT=$(realpath -m -- "$OUT")
lock() { jq -r "$@" "$LOCK"; }
jq -e '[.reads.url, .index.url, .truth[].url, .reference.url] | all(test("^https://[^?#@]+$"))' "$LOCK" >/dev/null ||
    die 'Unexpected source URL in lock file'
if ((!DOWNLOAD)); then
    jq --arg out "$OUT" '{mode: "plan", out: $out, region, budget_bytes: .download_budget_bytes,
        scratch_bytes: .scratch_reservation_bytes, reads: "index-selected byte ranges of \(.reads.name) only",
        truth: [.truth[].name], reference: "\(.reference.name) by FAI offsets"}' "$LOCK"
    exit 0
fi

for tool in samtools bcftools jq; do command -v "$tool" >/dev/null || die "Missing $tool; run make first"; done
[[ -x $ROOT/build/region-ranges ]] || die 'Missing build/region-ranges; run make first'
mkdir -p -- "$OUT"
(($(stat -f -c '%a * %S' -- "$OUT") >= $(lock .scratch_reservation_bytes))) || die 'Insufficient free disk'
exec 9>"$OUT/prepare.lock"
flock -n 9 || die "Another preparation holds $OUT/prepare.lock"
cp -- "$LOCK" "$OUT/source-lock-used.json"
REGION=$(lock .region)

# ---- BAM index, header and interval ranges -------------------------------------------
BAI=$OUT/source/$(lock .index.name)
fetch_file "$BAI" "$(lock .index.url)" "$(lock .index.bytes)"
[[ $(md5 "$BAI") == "$(lock .index.md5)" ]] || die 'BAM index MD5 differs from the GIAB checksum list'
BAM_URL=$(lock .reads.url) BAM_BYTES=$(lock .reads.bytes)
CACHE=$OUT/source/bam-chunks
HEADER_REQUESTS=$(printf '0 %s\n' "$(($(lock .reads.header_bytes) - 1))" | split_ranges "$CACHE" bgzf)
fetch_ranges "$BAM_URL" "$BAM_BYTES" "$HEADER_REQUESTS"
HEADER=$OUT/source/header.bam
while read -r _ _ path; do cat -- "$path"; done <<<"$HEADER_REQUESTS" >"$HEADER"
INDEXED=$("$ROOT/build/region-ranges" "$BAI" "$REGION" "$HEADER" 2>/dev/null) || die 'Cannot plan BAM ranges'
REQUESTS=$(jq -r --argjson size "$BAM_BYTES" '(. + [{start: ($size - 28), end: ($size - 1)}])[]
    | "\(.start) \([.end, $size - 1] | min)"' <<<"$INDEXED" | split_ranges "$CACHE" bgzf)
RANGE_BYTES=$(awk '{t += $2 - $1 + 1} END {printf "%.0f", t}' <<<"$REQUESTS")
((RANGE_BYTES <= $(lock .download_budget_bytes))) || die "Interval ranges ($RANGE_BYTES bytes) exceed the download budget"
fetch_ranges "$BAM_URL" "$BAM_BYTES" "$REQUESTS"

# Sparse local BAM: header and selected ranges at their original offsets.
SPARSE=$OUT/source/region-cache.bam
rm -f -- "$SPARSE"
truncate -s "$BAM_BYTES" -- "$SPARSE"
while read -r start _ path; do
    dd if="$path" of="$SPARSE" bs=1M seek="$start" oflag=seek_bytes conv=notrunc status=none
done <<<"$HEADER_REQUESTS"$'\n'"$REQUESTS"
cp -- "$BAI" "$SPARSE.bai"

# ---- read pairs ----------------------------------------------------------------------
READS=$OUT/reads
mkdir -p -- "$READS"
samtools view -u -F 0x900 -o "$READS/interval.bam" "$SPARSE" "$REGION"
samtools collate -u -O -T "$READS/collate" "$READS/interval.bam" |
    samtools fastq -n -F 0x900 -1 "$READS/HG002_1.fastq.gz" -2 "$READS/HG002_2.fastq.gz" -0 /dev/null -s /dev/null -c 6 -
PAIRS=$(($(zcat -- "$READS/HG002_1.fastq.gz" | wc -l) / 4))
((PAIRS > 0)) || die 'No read pairs extracted'
rm -f -- "$READS/interval.bam"

# ---- reference and truth -------------------------------------------------------------
REFERENCE=$OUT/reference/chr20.fa
mkdir -p -- "$OUT/reference"
[[ -f $REFERENCE ]] || fetch_reference_contig "$(lock .reference)" "$REFERENCE" "$OUT/source/reference-chunks"
jq -r '.truth[] | [.name, .url, (.bytes // "")] | @tsv' "$LOCK" | while IFS=$'\t' read -r name url bytes; do
    fetch_file "$OUT/truth/$name" "$url" "$bytes"
done
TRUTH=$OUT/truth/$(lock '.truth[0].name') BED=$OUT/truth/$(lock '.truth[2].name')
bcftools index -n "$TRUTH" >/dev/null || die 'Benchmark VCF index is unusable'

# ---- workflow configuration and provenance -------------------------------------------------
jq -n --arg out "$OUT" --arg sha "$(sha256 "$REFERENCE")" --argjson reads_bytes \
    "$(($(stat -c %s -- "$READS/HG002_1.fastq.gz") + $(stat -c %s -- "$READS/HG002_2.fastq.gz")))" '{
    schema_version: 1, workflow_type: "reads", work_dir: "\($out)/analysis", assembly: "GRCh38 chr20 (1000 Genomes analysis set)",
    reference: "\($out)/reference/chr20.fa", reference_sha256: $sha,
    runs: [{id: "hg002_2x250", sample: "HG002", library: "giab_2x250",
            read1: "\($out)/reads/HG002_1.fastq.gz", read2: "\($out)/reads/HG002_2.fastq.gz"}],
    resources: {threads: 8, memory_mb: 6144},
    limits: {input_bytes: ($reads_bytes + 1), reference_bases: 70000000, scratch_bytes: 20000000000},
    processing: {threads: 4, memory_mb: 4096, timeout_seconds: 86400, max_fragment: 1000,
                 min_mapping_quality: 20, min_base_quality: 20, max_depth: 250},
    qc: {min_dp: 10, min_gq: 20}}' >"$OUT/config.json"
jq -n --slurpfile lock "$LOCK" --argjson pairs "$PAIRS" --argjson range_bytes "$RANGE_BYTES" \
    --arg bai "$(md5 "$BAI")" --arg reference "$(sha256 "$REFERENCE")" --arg truth "$(sha256 "$TRUTH")" --arg bed "$(sha256 "$BED")" \
    --arg read1 "$(sha256 "$READS/HG002_1.fastq.gz")" --arg read2 "$(sha256 "$READS/HG002_2.fastq.gz")" \
    --arg prepared "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
    prepared_utc: $prepared, sample: "HG002", region: $lock[0].region, read_pairs: $pairs,
    downloaded_bam_range_bytes: $range_bytes, bam_index_md5_verified: $bai,
    read1_sha256: $read1, read2_sha256: $read2, reference_fasta_sha256: $reference,
    truth_vcf_sha256: $truth, truth_bed_sha256: $bed, truth_checksum_note: $lock[0].truth_checksum_note,
    selection: "Primary alignments (not secondary/supplementary) overlapping the region in the GIAB novoalign BAM; pairs with both mates overlapping kept; singletons dropped. Selection depends on the original alignment, and reads are re-aligned only to chr20, so off-target and paralog effects are not represented.",
    scope: "Bounded single-sample interval accuracy check of the reads workflow; not genome-wide calling accuracy"}' >"$OUT/prepared.json"
echo "Prepared GIAB HG002 check ($PAIRS read pairs): $OUT/config.json"
