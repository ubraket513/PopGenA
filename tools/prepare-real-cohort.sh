#!/usr/bin/env bash
# Prepare the bounded real-data genotype validation: 200 individuals from the 1000 Genomes
# 2,504-person panel, chr21:15,000,000-16,000,000 from the NYGC 3,202-person phased release.
#
# Only index-derived byte ranges of the source VCF and one chromosome range of the original
# reference FASTA are fetched (tools/real-cohort.lock.json). Default is plan-only.
#   --download     fetch missing ranges (verified ranges in the cache are reused)
#   --reuse DIR    seed the cache from an earlier preparation directory; every chunk is
#                  re-verified, so this never trusts unverified bytes
set -euo pipefail
export PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/.deps/linux/prefix/bin:$PATH" # vendored jq first

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
LOCK=$ROOT/tools/real-cohort.lock.json
BIN=$ROOT/.deps/linux/prefix/bin
OUT=$ROOT/work/real-validation-linux DOWNLOAD=0 REUSE=
while (( $# )); do
    case $1 in
        --out) OUT=$2; shift 2 ;;
        --download) DOWNLOAD=1; shift ;;
        --reuse) REUSE=$2; shift 2 ;;
        *) echo 'Usage: prepare-real-cohort.sh [--out DIR] [--download] [--reuse DIR]' >&2; exit 2 ;;
    esac
done
die() { echo "Error: $*" >&2; exit 1; }
OUT=$(realpath -m -- "$OUT")
sha256() { sha256sum -- "$1" | cut -d' ' -f1; }
md5() { md5sum -- "$1" | cut -d' ' -f1; }
lock() { jq -r "$@" "$LOCK"; }

jq -e '[.files[], .metadata[] | .url | test("^https://ftp\\.1000genomes\\.ebi\\.ac\\.uk/[^?#@]*$")] | all' "$LOCK" >/dev/null \
    || die 'Unexpected validation source'
PLAN=$(jq --arg out "$OUT" '{download_bytes_upper_bound: 81000000, budget_bytes: .download_budget_bytes,
    scratch_bytes: .scratch_reservation_bytes, out: $out, selection,
    source_files_not_whole_downloads: (.files + .metadata),
    method: "Index-derived HTTP ranges plus original chromosome FASTA range; whole source VCF MD5 cannot be verified"}' "$LOCK")
if (( ! DOWNLOAD )); then printf '%s\n' "$PLAN"; exit 0; fi

for tool in "$BIN/samtools" "$BIN/bcftools" "$ROOT/build/region-ranges"; do
    [[ -x $tool ]] || die "Missing $tool; run make first"
done
mkdir -p -- "$OUT"
EXISTING=$OUT
(( $(stat -f -c '%a * %S' -- "$EXISTING") >= $(lock .scratch_reservation_bytes) )) || die 'Insufficient free disk for validation reservation'
exec 9>"$OUT/prepare.lock"
flock -n 9 || die "Another preparation holds $OUT/prepare.lock"
cp -- "$LOCK" "$OUT/source-lock-used.json"
printf '%s\n' "$PLAN" >"$OUT/download-plan.json"

# ---- chunk cache -----------------------------------------------------------------
# A chunk is valid when its size matches and its recorded SHA256 matches its content.
valid_chunk() { [[ -f $1 && -f $1.sha256 && $(stat -c %s -- "$1") == "$2" && $(sha256 "$1") == "$(tr -d ' \r\n' <"$1.sha256")" ]]; }
seed() { # seed <subdir>: copy verified chunks from --reuse
    [[ -n $REUSE && -d $REUSE/$1 ]] || return 0
    mkdir -p -- "$OUT/$1"
    local chunk
    for chunk in "$REUSE/$1"/*; do
        case $chunk in *.sha256|*.headers|*.part) continue ;; esac
        [[ -f $chunk.sha256 && ! -e $OUT/$1/${chunk##*/} ]] || continue
        [[ $(sha256 "$chunk") == "$(tr -d ' \r\n' <"$chunk.sha256")" ]] || continue
        cp -- "$chunk" "$OUT/$1/" && cp -- "$chunk.sha256" "$OUT/$1/"
    done
}
# fetch_ranges <url> <expected Content-Range total regex> <request lines "start end path">
fetch_ranges() {
    local url=$1 total=$2 requests=$3 start end path size args=() failed=0
    while read -r start end path; do
        size=$(( end - start + 1 ))
        valid_chunk "$path" "$size" && continue
        (( ${#args[@]} )) && args+=(--next)
        args+=(--fail --silent --show-error --proto =https --connect-timeout 30 --max-time 180 --max-filesize "$size"
               --range "$start-$end" --dump-header "$path.headers" --output "$path.part" "$url")
    done <<<"$requests"
    if (( ${#args[@]} )); then curl --parallel --parallel-max 4 "${args[@]}" || failed=1; fi
    while read -r start end path; do
        size=$(( end - start + 1 ))
        if [[ -f $path.part && $(stat -c %s -- "$path.part") == "$size" ]]; then
            grep -qiE "^Content-Range: bytes $start-$end/$total"$'\r?$' "$path.headers" \
                || die 'Server did not return the exact requested range'
            mv -f -- "$path.part" "$path"
            sha256 "$path" >"$path.sha256"
        fi
        valid_chunk "$path" "$size" || failed=1
    done <<<"$requests"
    (( ! failed )) || die 'A bounded range transfer failed; verified completed ranges can be reused'
}

# ---- metadata and index ---------------------------------------------------------------
fetch_file() { # fetch_file <name> <bytes> <url>
    local path=$OUT/$1
    [[ -e $path || -z $REUSE || ! -f $REUSE/$1 ]] || cp -- "$REUSE/$1" "$path"
    if [[ ! -e $path ]]; then
        curl --fail --silent --show-error --proto =https --max-time 60 --max-filesize "$2" --output "$path.part" -- "$3"
        [[ $(stat -c %s -- "$path.part") == "$2" ]] || die "Metadata download failed: $1"
        mv -- "$path.part" "$path"
    fi
}
INDEX=$(lock '.files[] | select(.name == "chr21.vcf.gz.tbi")')
fetch_file chr21.vcf.gz.tbi "$(jq -r .bytes <<<"$INDEX")" "$(jq -r .url <<<"$INDEX")"
[[ $(md5 "$OUT/chr21.vcf.gz.tbi") == "$(jq -r .md5 <<<"$INDEX")" ]] || die 'Index MD5 differs from release manifest'
PANEL=$(lock '.metadata[0]')
fetch_file original-panel.tsv "$(jq -r .bytes <<<"$PANEL")" "$(jq -r .url <<<"$PANEL")"
[[ $(sha256 "$OUT/original-panel.tsv") == "$(jq -r .sha256 <<<"$PANEL")" ]] || die 'Original panel hash differs'

# ---- genotype byte ranges ---------------------------------------------------------------
SOURCE=$(lock '.files[] | select(.name == "chr21.vcf.gz")')
SOURCE_URL=$(jq -r .url <<<"$SOURCE") SOURCE_BYTES=$(jq -r .bytes <<<"$SOURCE")
REGION=chr21:15000000-16000000
INDEXED=$("$ROOT/build/region-ranges" "$OUT/chr21.vcf.gz.tbi" "$REGION") || die 'Cannot plan indexed ranges'
seed region-chunks
mkdir -p -- "$OUT/region-chunks"
# Header block, index-selected BGZF chunks and the 28-byte EOF block, split into 1 MiB requests.
REQUESTS=$(jq -r --argjson size "$SOURCE_BYTES" --arg cache "$OUT/region-chunks" '
    ([{start: 0, end: 524287}] + . + [{start: ($size - 28), end: ($size - 1)}])[]
    | if .start < 0 or .end >= $size or .end < .start then error("Invalid indexed byte range") else . end
    | . as $r | range($r.start; $r.end + 1; 1048576) as $s
    | [$s, ([$s + 1048575, $r.end] | min)] | "\(.[0]) \(.[1]) \($cache)/\(.[0])-\(.[1]).bgzf"' <<<"$INDEXED")
RANGE_BYTES=$(awk '{t += $2 - $1 + 1} END {print t}' <<<"$REQUESTS")
(( RANGE_BYTES <= 32000000 )) || die 'Indexed genotype selection exceeds 32 MB byte budget'
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
while read -r start end path; do
    dd if="$path" of="$VCF" bs=1M seek="$start" oflag=seek_bytes conv=notrunc status=none
done <<<"$REQUESTS"
cp -- "$OUT/chr21.vcf.gz.tbi" "$VCF.tbi"
touch -- "$VCF.tbi"
HASHES=$(while read -r start end path; do printf '{"start":%s,"end":%s,"sha256":"%s"}\n' "$start" "$end" "$(sha256 "$path")"; done <<<"$REQUESTS" | jq -s .)
jq --argjson hashes "$HASHES" '. + {downloaded_range_sha256: $hashes}' <<<"$REGION_PLAN" >"$OUT/region-provenance.json"

# ---- reference chromosome range ------------------------------------------------------------
REFERENCE=$(lock '.files[] | select(.name == "chr21.sequence.txt")')
read -r REF_URL REF_START BASES LINE_BASES LINE_BYTES REF_MD5 < <(jq -r '[.url, .range_start, .bases, .line_bases, .line_bytes, .sequence_md5] | @tsv' <<<"$REFERENCE")
REF_BYTES=$(( (BASES - 1) / LINE_BASES * LINE_BYTES + (BASES - 1) % LINE_BASES + 1 ))
(( REF_BYTES <= 48000000 )) || die 'Reference range exceeds 48 MB budget'
seed reference-chunks
mkdir -p -- "$OUT/reference-chunks"
REF_REQUESTS=$(awk -v first="$REF_START" -v bytes="$REF_BYTES" -v cache="$OUT/reference-chunks" 'BEGIN {
    for (offset = 0; offset < bytes; offset += 1048576) {
        start = first + offset; end = start + 1048575; if (end > first + bytes - 1) end = first + bytes - 1
        printf "%.0f %.0f %s/%.0f-%.0f.sequence\n", start, end, cache, start, end } }')
fetch_ranges "$REF_URL" '[0-9]+' "$REF_REQUESTS"
RAW=$OUT/chr21.sequence.txt
while read -r _ _ path; do cat -- "$path"; done <<<"$REF_REQUESTS" >"$RAW"
SEQUENCE_MD5=$(tr -d '\r\n' <"$RAW" | tr '[:lower:]' '[:upper:]' | tee >(wc -c >"$OUT/.sequence-length") | md5sum | cut -d' ' -f1)
wait
[[ $(tr -d ' ' <"$OUT/.sequence-length") == "$BASES" ]] || die 'Invalid reference sequence length'
rm -f -- "$OUT/.sequence-length"
! tr -d '\r\n' <"$RAW" | tr '[:lower:]' '[:upper:]' | grep -q '[^ACGTRYSWKMBDHVN]' || die 'Invalid reference sequence characters'
[[ $SEQUENCE_MD5 == "$REF_MD5" ]] || die 'Original reference sequence MD5 mismatch'
FASTA=$OUT/chr21.fa
{ printf '>chr21\n'; cat -- "$RAW"; printf '\n'; } >"$FASTA"
jq -n --arg source "$REF_URL" --argjson start "$REF_START" --argjson bytes "$REF_BYTES" --arg md5 "$SEQUENCE_MD5" --arg sha "$(sha256 "$FASTA")" \
    '{source: $source, start: $start, bytes: $bytes, sequence_md5: $md5, fasta_sha256: $sha,
      rejected_alternative: "UCSC hg38 chr21 sequence MD5 differs; not used"}' >"$OUT/reference-provenance.json"

# ---- selection, subset and workflow configuration --------------------------------------------
PANEL_ROWS=$(tail -n +2 "$OUT/original-panel.tsv" | tr -d '\r' | awk -F'\t' 'NF >= 3')
[[ $(wc -l <<<"$PANEL_ROWS") == 2504 && $(cut -f1 <<<"$PANEL_ROWS" | sort -u | wc -l) == 2504 ]] \
    || die 'Original panel identity/count changed'
SELECTED=$(for pop in AFR AMR EAS EUR SAS; do awk -F'\t' -v p="$pop" '$3 == p' <<<"$PANEL_ROWS" | LC_ALL=C sort -t$'\t' -k1,1 | head -40; done)
[[ $(wc -l <<<"$SELECTED") == 200 ]] || die 'Expected 200 selected individuals'
cut -f1 <<<"$SELECTED" >"$OUT/selected.txt"
{ printf 'sample\tpopulation\n'; cut -f1,2 <<<"$SELECTED"; } >"$OUT/samples.tsv"
{ printf 'sample\tpopulation\tsuperpopulation\n'; cut -f1-3 <<<"$SELECTED"; } >"$OUT/selection.tsv"

"$BIN/samtools" faidx "$FASTA"
BCF=$OUT/cohort.bcf
"$BIN/bcftools" view -r "$REGION" -S "$OUT/selected.txt" -m2 -M2 -v snps -f PASS -Ob -o "$BCF" "$VCF"
"$BIN/bcftools" index -f "$BCF"
COUNT=$("$BIN/bcftools" index -n "$BCF")
(( COUNT >= 10000 && COUNT <= 50000 )) || die "Subset outside planned 10k-50k SNP validation size: $COUNT"

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
