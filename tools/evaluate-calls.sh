#!/usr/bin/env bash
# Compare biallelic SNP calls for one sample with a benchmark VCF inside benchmark confident
# regions restricted to an interval. Reports precision, recall, F1 and genotype concordance.
#
# This is a transparent SNP-only comparison (match on CHROM/POS/REF/ALT; genotypes compared
# unphased). It does not replace haplotype-aware tools such as hap.py for indels/complex
# variants. Positions where either set has more than one ALT are excluded and counted.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export PATH="$ROOT/.deps/linux/prefix/bin:$PATH"

usage() {
    echo 'Usage: evaluate-calls.sh --calls calls.bcf --truth truth.vcf.gz --bed confident.bed --region chr:start-end [--margin N] [--sample NAME] --out report.json' >&2
    exit 2
}
CALLS= TRUTH= BED= REGION= MARGIN=0 SAMPLE= OUT=
while (($#)); do
    case $1 in
    --calls) CALLS=$2; shift 2 ;;
    --truth) TRUTH=$2; shift 2 ;;
    --bed) BED=$2; shift 2 ;;
    --region) REGION=$2; shift 2 ;;
    --margin) MARGIN=$2; shift 2 ;;
    --sample) SAMPLE=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    *) usage ;;
    esac
done
[[ -n $CALLS && -n $TRUTH && -n $BED && -n $REGION && -n $OUT ]] || usage
[[ $REGION =~ ^([^:]+):([0-9]+)-([0-9]+)$ ]] || { echo 'Region must be chr:start-end' >&2; exit 2; }
CHROM=${BASH_REMATCH[1]} FIRST=$((BASH_REMATCH[2] + MARGIN)) LAST=$((BASH_REMATCH[3] - MARGIN))
((FIRST <= LAST)) || { echo 'Margin removes the whole region' >&2; exit 2; }
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT

# Evaluation regions: confident BED intervals clipped to [FIRST, LAST] (BED is 0-based, half-open).
awk -F'\t' -v c="$CHROM" -v s="$((FIRST - 1))" -v e="$LAST" 'BEGIN {OFS = "\t"}
    $1 == c && $3 > s && $2 < e {print $1, ($2 > s ? $2 : s), ($3 < e ? $3 : e)}' "$BED" >"$TMP/eval.bed"
BASES=$(awk '{t += $3 - $2} END {printf "%.0f", t}' "$TMP/eval.bed")
((BASES > 0)) || { echo 'No confident bases in the region' >&2; exit 1; }

# extract <vcf> <label>: "chrom:pos:ref:alt<TAB>genotype" for non-reference SNP genotypes,
# with genotypes unphased and allele-ordered; multi-ALT positions go to <label>.multi.
extract() {
    local sample_args=()
    [[ -n $SAMPLE ]] && bcftools query -l "$1" | grep -qx -- "$SAMPLE" && sample_args=(-s "$SAMPLE")
    bcftools view -T "$TMP/eval.bed" -v snps "${sample_args[@]}" -Ou "$1" |
        bcftools query -f '%CHROM\t%POS\t%REF\t%ALT[\t%GT]\n' |
        awk -F'\t' -v multi="$TMP/$2.multi" '{
            if (index($4, ",")) { print $1 ":" $2 > multi; next }
            gt = $5; gsub(/\|/, "/", gt)
            if (gt == "1/0") gt = "0/1"
            if (gt == "0/1" || gt == "1/1") print $1 ":" $2 ":" $3 ":" $4 "\t" gt
        }' | LC_ALL=C sort >"$TMP/$2.tsv"
    touch "$TMP/$2.multi"
    # Positions called more than once (split multiallelic records) are ambiguous too.
    cut -d: -f1,2 "$TMP/$2.tsv" | LC_ALL=C sort | uniq -d >>"$TMP/$2.multi"
}
extract "$TRUTH" truth
extract "$CALLS" calls
LC_ALL=C sort -u "$TMP/truth.multi" "$TMP/calls.multi" >"$TMP/excluded"
for set in truth calls; do
    awk -F'\t' 'NR == FNR {skip[$1]; next} {split($1, k, ":"); if (!((k[1] ":" k[2]) in skip)) print}' \
        "$TMP/excluded" "$TMP/$set.tsv" >"$TMP/$set.kept"
done

read -r TP GT_MATCH FP FN < <(LC_ALL=C join -t $'\t' -a1 -a2 -e MISSING -o 0,1.2,2.2 "$TMP/truth.kept" "$TMP/calls.kept" |
    awk -F'\t' '{
        if ($2 == "MISSING") fp++
        else if ($3 == "MISSING") fn++
        else { tp++; if ($2 == $3) same++ }
    } END {printf "%d %d %d %d\n", tp, same, fp, fn}')
mkdir -p -- "$(dirname -- "$OUT")"
jq -n --arg calls "$CALLS" --arg truth "$TRUTH" --arg bed "$BED" --arg region "$REGION" --argjson margin "$MARGIN" \
    --arg evaluated "$CHROM:$FIRST-$LAST" --argjson bases "$BASES" --argjson tp "$TP" --argjson gt "$GT_MATCH" \
    --argjson fp "$FP" --argjson fn "$FN" --argjson excluded "$(wc -l <"$TMP/excluded")" '
    def ratio(a; b): if b == 0 then null else (a / b * 1000000 | round) / 1000000 end;
    {calls: $calls, truth: $truth, confident_regions: $bed, region: $region, margin_bases: $margin,
     evaluated_interval: $evaluated, confident_bases_evaluated: $bases,
     snps: {true_positive: $tp, false_positive: $fp, false_negative: $fn, genotype_match: $gt,
            excluded_multiallelic_positions: $excluded,
            precision: ratio($tp; $tp + $fp), recall: ratio($tp; $tp + $fn),
            f1: ratio(2 * $tp; 2 * $tp + $fp + $fn), genotype_concordance: ratio($gt; $tp)},
     method: "Biallelic SNPs in confident regions; match on CHROM/POS/REF/ALT; unphased genotype comparison; not haplotype-aware (indels and complex variants not evaluated)"}' >"$OUT"
cat "$OUT"
