#!/usr/bin/env bash
# Prepare a whole-chromosome genotype workflow for the original 2,504-person 1000 Genomes
# panel from the NYGC phased release (scripts/sources/1000g-chr22.lock.json by default).
# The whole chromosome VCF is downloaded and verified against the release manifest MD5.
# Default is plan-only; --download fetches.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
export PATH="$ROOT/.deps/linux/prefix/bin:$PATH"
source "$ROOT/scripts/lib/fetch.sh"

LOCK=$ROOT/scripts/sources/1000g-chr22.lock.json OUT='' DOWNLOAD=0
while (($#)); do
    case $1 in
    --lock) LOCK=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --download) DOWNLOAD=1; shift ;;
    *) echo 'Usage: prepare-1000g-chromosome.sh [--lock FILE] [--out DIR] [--download]' >&2; exit 2 ;;
    esac
done
lock() { jq -r "$@" "$LOCK"; }
CHROM=$(lock .chromosome)
OUT=$(realpath -m -- "${OUT:-$ROOT/work/1000g-$CHROM}")
jq -e '[.files[].url, .reference.url] | all(test("^https://ftp\\.1000genomes\\.ebi\\.ac\\.uk/[^?#@]*$"))' "$LOCK" >/dev/null ||
    die 'Unexpected source URL in lock file'
(($(lock '[.files[].bytes] | add') <= $(lock .download_budget_bytes))) || die 'Files exceed the download budget'
if ((!DOWNLOAD)); then
    jq --arg out "$OUT" '{mode: "plan", out: $out, chromosome, selection, budget_bytes: .download_budget_bytes,
        download_bytes: ([.files[].bytes] | add), scratch_bytes: .scratch_reservation_bytes, files: [.files[].name],
        reference: "\(.reference.name) by FAI offsets"}' "$LOCK"
    exit 0
fi

command -v bcftools >/dev/null && command -v samtools >/dev/null || die 'Missing bcftools/samtools; run make first'
mkdir -p -- "$OUT/source"
(($(stat -f -c '%a * %S' -- "$OUT") >= $(lock .scratch_reservation_bytes))) || die 'Insufficient free disk'
exec 9>"$OUT/prepare.lock"
flock -n 9 || die "Another preparation holds $OUT/prepare.lock"
cp -- "$LOCK" "$OUT/source-lock-used.json"

# Fields joined by the ASCII unit separator: unlike tab, read does not collapse empty fields.
jq -r '.files[] | [.name, .url, .bytes, (.md5 // ""), (.sha256 // "")] | join("\u001f")' "$LOCK" |
    while IFS=$'\x1f' read -r name url bytes md5sum_expected sha256_expected; do
        path=$OUT/source/$name
        if ((bytes > 67108864)); then
            fetch_file_ranged "$path" "$url" "$bytes" "$OUT/source/$name.chunks"
        else
            fetch_file "$path" "$url" "$bytes"
        fi
        [[ -z $md5sum_expected || $(md5 "$path") == "$md5sum_expected" ]] || { rm -f -- "$path"; die "MD5 mismatch: $name"; }
        [[ -z $sha256_expected || $(sha256 "$path") == "$sha256_expected" ]] || die "SHA256 mismatch: $name"
    done

PANEL=$(tail -n +2 "$OUT/source/original-panel.tsv" | tr -d '\r' | awk -F'\t' 'NF >= 3')
[[ $(wc -l <<<"$PANEL") == 2504 && $(cut -f1 <<<"$PANEL" | sort -u | wc -l) == 2504 ]] || die 'Original panel identity/count changed'
LC_ALL=C sort -t$'\t' -k1,1 <<<"$PANEL" | cut -f1 >"$OUT/selected.txt"
{ printf 'sample\tpopulation\n'; LC_ALL=C sort -t$'\t' -k1,1 <<<"$PANEL" | cut -f1,2; } >"$OUT/samples.tsv"

FASTA=$OUT/$CHROM.fa
[[ -f $FASTA ]] || fetch_reference_contig "$(lock .reference)" "$FASTA" "$OUT/source/reference-chunks"
samtools faidx "$FASTA"

BCF=$OUT/cohort.bcf
bcftools view --threads 2 -S "$OUT/selected.txt" -m2 -M2 -v snps -f PASS -Ob -o "$BCF" "$OUT/source/$(lock '.files[0].name')"
bcftools index -f "$BCF"
rm -rf -- "$OUT/source/"*.chunks # the verified whole file replaces its range cache
SITES=$(bcftools index -n "$BCF" 2>/dev/null)
SAMPLES=$(bcftools query -l "$BCF" | wc -l)
((SAMPLES == 2504)) || die "Expected 2504 samples in the subset, found $SAMPLES"

jq -n --arg out "$OUT" --arg chrom "$CHROM" '{schema_version: 1, workflow_type: "genotypes", work_dir: "\($out)/analysis",
    assembly: "GRCh38 \($chrom); NYGC 20201028 phased release",
    input: "\($out)/cohort.bcf", reference: "\($out)/\($chrom).fa", reference_index: "\($out)/\($chrom).fa.fai",
    samples: "\($out)/samples.tsv",
    resources: {threads: 8, memory_mb: 6144}, qc: {min_dp: 0, min_gq: 0, sample_missing: 0.1, variant_missing: 0.1},
    analysis: {pcs: 10, pca_maf: 0.05, kinship_maf: 0.05, kinship_threshold: 0.0884, relatedness_policy: "retain",
               ld_window: 50, ld_step: 5, ld_r2: 0.2, threads: 4, memory_mb: 4096}}' >"$OUT/config.json"
jq -n --slurpfile lock "$LOCK" --argjson sites "$SITES" --arg vcf_md5 "$(md5 "$OUT/source/$(lock '.files[0].name')")" \
    --arg reference "$(sha256 "$FASTA")" --arg input "$(sha256 "$BCF")" --arg prepared "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
    prepared_utc: $prepared, chromosome: $lock[0].chromosome, samples: 2504, sites: $sites,
    source_vcf_md5_verified: $vcf_md5, reference_sha256: $reference, input_sha256: $input, selection: $lock[0].selection,
    quality_policy: "Phased release GT only; DP/GQ filters explicitly disabled, not synthesized",
    relatedness_policy: "retain: one chromosome cannot establish genome-wide kinship; pairs are reported",
    scope: $lock[0].purpose}' >"$OUT/prepared.json"
echo "Prepared 1000 Genomes $CHROM (2504 samples, $SITES SNPs): $OUT/config.json"
