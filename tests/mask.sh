#!/usr/bin/env bash
# Adversarial genotype masking: quality thresholds, phase/INFO handling, malformed
# quality fields, unsorted/truncated inputs and non-destructive outputs.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TEST_ROOT=$(new_test_root mask)

HEADER='##fileformat=VCFv4.3
##contig=<ID=1,length=1000>
##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
##FORMAT=<ID=DP,Number=1,Type=Integer,Description="Depth">
##FORMAT=<ID=GQ,Number=1,Type=Integer,Description="Quality">
##INFO=<ID=AC,Number=A,Type=Integer,Description="Allele count">
##INFO=<ID=AN,Number=1,Type=Integer,Description="Allele number">
##INFO=<ID=AF,Number=A,Type=Float,Description="Allele frequency">
##INFO=<ID=NS,Number=1,Type=Integer,Description="Samples">
#CHROM POS ID REF ALT QUAL FILTER INFO FORMAT A B'

# fixture <name> <header> <rows...>: write space-separated rows as a VCF, convert to BCF.
fixture() {
    local name=$1 header=$2; shift 2
    { printf '%s\n' "$header"; printf '%s\n' "$@"; } | tr ' ' '\t' >"$TEST_ROOT/$name.vcf"
    bcf view --no-version -Ob -o "$TEST_ROOT/$name.bcf" "$TEST_ROOT/$name.vcf"
    printf '%s\n' "$TEST_ROOT/$name.bcf"
}
mask() { cli mask "$@"; }

INPUT=$(fixture calls "$HEADER" \
    '1 10 phase A C . PASS AC=2;AN=4;AF=0.5;NS=2 GT:DP:GQ 0|1:20:30 1|0:20:30' \
    '1 20 low A C . . AC=2;AN=4;AF=0.5;NS=2 GT:DP:GQ 0/1:9:30 0/1:20:19' \
    '1 30 missing-quality A C . PASS . GT:DP:GQ 0/1:.:30 0/1:20:.' \
    '1 40 ploidy A C . PASS . GT:DP:GQ 1:20:30 0/1/1:20:30' \
    '1 50 missing-gt A C . PASS . GT:DP:GQ 0/.:20:30 ./.:20:30')
OUTPUT=$TEST_ROOT/masked.bcf
mask --input "$INPUT" --out "$OUTPUT" --min-dp 10 --min-gq 20
REPORT=$TEST_ROOT/report.json
cp "$TEST_ROOT/stdout.txt" "$REPORT"
check 'mask record/sample counts wrong' test "$(json "$REPORT" '"\(.kept) \(.sample_count)"')" = '5 2'
check 'mask reason counts wrong' test "$(json "$REPORT" '.genotypes | "\(.kept) \(.quality) \(.unsupported) \(.missing)"')" = '2 4 2 2'
mapfile -t ROWS < <(bcf query -f '%POS\t%ID\t%INFO[\t%GT]\n' "$OUTPUT")
check 'phase, ID, or removal of stale INFO failed' test "${ROWS[0]}" = $'10\tphase\t.\t0|1\t1|0'
for row in "${ROWS[@]:1}"; do
    check 'rejected calls were not diploid missing' test "${row: -8}" = $'\t./.\t./.'
done
check 'CSI regional access failed' test "$(bcf query -r 1:20-30 -f '%POS\n' "$OUTPUT" | paste -sd,)" = '20,30'
check 'per-sample masking counts wrong' test "$(json "$REPORT" '.samples | "\(length) \(.[0].masked) \(.[1].masked)"')" = '2 4 4'

# A requested quality field absent from the header masks every call.
NO_QUALITY=$(fixture no-quality "$(grep -vE '^##FORMAT=<ID=(DP|GQ),' <<<"$HEADER")" '1 10 . A C . PASS . GT 0|1 1/1')
for option in --min-dp --min-gq; do
    out=$TEST_ROOT/${option#--}.bcf
    mask --input "$NO_QUALITY" --out "$out" "$option" 1
    check 'absent requested quality did not mask calls' test "$(bcf query -f '[%GT,]' "$out")" = './.,./.,'
done
# Threshold zero disables quality requirements.
mask --input "$NO_QUALITY" --out "$TEST_ROOT/disabled.bcf"
check 'disabled quality thresholds changed GT' test "$(bcf query -f '[%GT,]' "$TEST_ROOT/disabled.bcf")" = '0|1,1/1,'

# Wrong declared type, vector-valued scalar and negative quality are explicit errors.
FLOAT_DP=$(fixture float-dp "${HEADER/ID=DP,Number=1,Type=Integer/ID=DP,Number=1,Type=Float}" '1 10 . A C . PASS . GT:DP 0/1:12.5 1/1:20.5')
VECTOR_DP=$(fixture vector-dp "${HEADER/ID=DP,Number=1/ID=DP,Number=2}" '1 10 . A C . PASS . GT:DP 0/1:12,13 1/1:20,21')
NEGATIVE_DP=$(fixture negative-dp "$HEADER" '1 10 . A C . PASS . GT:DP 0/1:-1 1/1:20')
for bad in "$FLOAT_DP" "$VECTOR_DP" "$NEGATIVE_DP"; do
    cli --fail mask --input "$bad" --out "$bad.masked.bcf" --min-dp 1
    check 'malformed quality published output' test ! -e "$bad.masked.bcf"
done
UNSORTED=$(fixture unsorted "$HEADER" '1 20 . A C . PASS . GT 0/1 1/1' '1 10 . A C . PASS . GT 0/1 1/1')
cli --fail mask --input "$UNSORTED" --out "$TEST_ROOT/unsorted.masked.bcf"
check 'unsorted input published output' test ! -e "$TEST_ROOT/unsorted.masked.bcf"
# Drop the 28-byte BGZF EOF block while preserving otherwise readable records.
truncate_tail "$INPUT" "$TEST_ROOT/truncated.bcf" 28
cli --fail mask --input "$TEST_ROOT/truncated.bcf" --out "$TEST_ROOT/truncated.masked.bcf"
check 'truncated input published output' test ! -e "$TEST_ROOT/truncated.masked.bcf"

# Existing outputs and index-only paths must keep their exact bytes.
BEFORE=$(digest "$OUTPUT") INDEX_BEFORE=$(digest "$OUTPUT.csi")
cli --fail mask --input "$INPUT" --out "$OUTPUT"
check 'existing BCF changed' test "$(digest "$OUTPUT")" = "$BEFORE"
check 'existing CSI changed' test "$(digest "$OUTPUT.csi")" = "$INDEX_BEFORE"
INDEX_ONLY=$TEST_ROOT/index-only.bcf
printf 'owned elsewhere' >"$INDEX_ONLY.csi"
INDEX_DIGEST=$(digest "$INDEX_ONLY.csi")
cli --fail mask --input "$INPUT" --out "$INDEX_ONLY"
check 'existing index-only path was changed' test ! -e "$INDEX_ONLY" -a "$(digest "$INDEX_ONLY.csi")" = "$INDEX_DIGEST"
echo "Adversarial genotype masking checks passed: $TEST_ROOT"
