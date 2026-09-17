#!/usr/bin/env bash
# Streamed statistics: golden outputs, format equivalence, masking, adversarial inputs
# and safe replacement.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TEST_ROOT=$(new_test_root integration)
VCF=$PROJECT/tests/data/fixtures/cohort.vcf
META=$PROJECT/tests/data/fixtures/samples.tsv

# stats <input> <out> [--fail] [extra args...]; a failed run must not publish output.
stats() {
    local input=$1 out=$2 expect=
    shift 2
    [[ ${1-} == --fail ]] && { expect=--fail; shift; }
    cli $expect stats --input "$input" --out "$out" "$@"
    [[ -z $expect || ! -e $out ]] || fail "failed analysis published $out"
}

stats "$VCF" "$TEST_ROOT/plain" --samples "$META"
for name in samples.tsv populations.tsv; do
    check "independent golden mismatch: $name" cmp -s "$TEST_ROOT/plain/$name" "$PROJECT/tests/data/golden/$name"
done
P=$TEST_ROOT/plain/provenance.json
check 'record accounting mismatch' test "$(json "$P" '"\(.eligible_sites) \(.records)"')" = '5 9'
check 'skip accounting mismatch' test "$(json "$P" '.skipped | "\(.non_autosomal) \(.not_biallelic_snp) \(.site_filter)"')" = '1 2 1'
# column lookups by header name
column() { awk -F'\t' -v row="$2" -v col="$3" 'NR==1{for(i=1;i<=NF;i++)h[$i]=i;next} NR==row+1{print $h[col]}' "$1"; }
SITES=$TEST_ROOT/plain/sites.tsv
check 'first-site estimator mismatch' test "$(column "$SITES" 1 observed_heterozygosity) $(column "$SITES" 1 expected_heterozygosity)" = '0.333333333333 0.5'
check 'all-missing site mishandled' test "$(column "$SITES" 3 called) $(column "$SITES" 3 alt_frequency)" = '0 NA'

bcf view -Ob -o "$TEST_ROOT/cohort.bcf" "$VCF"
bcf view -Oz -o "$TEST_ROOT/cohort.vcf.gz" "$VCF"
for format in bcf vcf.gz; do
    stats "$TEST_ROOT/cohort.$format" "$TEST_ROOT/$format" --samples "$META" --threads 1
    for name in samples.tsv sites.tsv populations.tsv population_sites.tsv; do
        check "format/thread mismatch: $format $name" cmp -s "$TEST_ROOT/plain/$name" "$TEST_ROOT/$format/$name"
    done
done

stats "$VCF" "$TEST_ROOT/quality" --samples "$META" --min-dp 10 --min-gq 20
Q=$TEST_ROOT/quality/samples.tsv
check 'DP/absent quality masking incorrect' test "$(column "$Q" 1 called) $(column "$Q" 1 quality_filtered)" = '2 2'
check 'GQ masking incorrect' test "$(column "$Q" 3 called) $(column "$Q" 3 quality_filtered)" = '2 1'

BEFORE=$(digest "$TEST_ROOT/plain/samples.tsv")
stats "$VCF" "$TEST_ROOT/plain" --samples "$META" --replace
check 'replacement changed results' test "$(digest "$TEST_ROOT/plain/samples.tsv")" = "$BEFORE"

UNICODE="$TEST_ROOT/space & 샘플"
mkdir "$UNICODE" && cp "$VCF" "$UNICODE/input.vcf"
stats "$UNICODE/input.vcf" "$UNICODE/result" --samples "$META"
check 'Unicode/space path mismatch' test "$(digest "$UNICODE/result/samples.tsv")" = "$BEFORE"

printf 'sample\tpopulation\nS1\tA\nS1\tB\n' >"$TEST_ROOT/bad.tsv"
stats "$VCF" "$TEST_ROOT/bad-meta" --fail --samples "$TEST_ROOT/bad.tsv"
sed 's#0/0:20:50#0/8:20:50#g' "$VCF" >"$TEST_ROOT/bad.vcf"
stats "$TEST_ROOT/bad.vcf" "$TEST_ROOT/bad-allele" --fail
{ cat "$VCF"; printf '1\t95\tbad\tA\tG\n'; } >"$TEST_ROOT/truncated.vcf"
stats "$TEST_ROOT/truncated.vcf" "$TEST_ROOT/bad-record" --fail
truncate_tail "$TEST_ROOT/cohort.bcf" "$TEST_ROOT/truncated.bcf" 28
stats "$TEST_ROOT/truncated.bcf" "$TEST_ROOT/bad-compressed" --fail

sed -E 's/\tS4(\r?)$/\tS1\1/' "$VCF" >"$TEST_ROOT/duplicate-sample.vcf"
sed 's/ID=GQ,Number=1,Type=Integer/ID=GQ,Number=1,Type=Float/' "$VCF" >"$TEST_ROOT/wrong-quality-type.vcf"
sed -e 's/^1\t/X\t/' -e 's/^chr2\t/X\t/' "$VCF" >"$TEST_ROOT/no-eligible.vcf"
: >"$TEST_ROOT/empty.vcf"
for variant in duplicate-sample wrong-quality-type no-eligible empty; do
    stats "$TEST_ROOT/$variant.vcf" "$TEST_ROOT/invalid-$variant" --fail --min-gq 20
done

# A failed replacement preserves the prior complete result.
cli --fail stats --input "$TEST_ROOT/bad.vcf" --out "$TEST_ROOT/plain" --replace
check 'failed replacement damaged prior results' test "$(digest "$TEST_ROOT/plain/samples.tsv")" = "$BEFORE"
printf 'user data' >"$TEST_ROOT/plain/keep.txt"
cli --fail stats --input "$VCF" --out "$TEST_ROOT/plain" --replace
check 'replacement accepted unowned additional files' test "$(cat "$TEST_ROOT/plain/keep.txt")" = 'user data'

(cd "$TEST_ROOT" && stats "$VCF" "$TEST_ROOT/other-cwd" --samples "$META")
check 'result depends on caller directory' test "$(digest "$TEST_ROOT/other-cwd/samples.tsv")" = "$BEFORE"
check 'failed stage was not cleaned up' test -z "$(find "$TEST_ROOT" -maxdepth 1 -name '.popgen-stage-*')"
echo "Statistics integration checks passed; artifacts: $TEST_ROOT"
