#!/usr/bin/env bash
# Regenerate the deterministic synthetic genotype fixture (tests/fixtures/genotype).
# Offline, no random libraries: a fixed 32-bit LCG in awk (all values stay below 2^53,
# so double-precision arithmetic is exact).
set -euo pipefail
OUT=${1:-$(dirname -- "${BASH_SOURCE[0]}")/fixtures/genotype}
mkdir -p -- "$OUT"

awk -v out="$OUT/cohort.vcf" '
function next_random() {
    state = (state * 1664525 + 1013904223) % 4294967296
    return int(state / 256) # upper bits: the lowest LCG bits have short cycles
}
function abs(x) { return x < 0 ? -x : x }
function min(a, b) { return a < b ? a : b }
BEGIN {
    state = 1729; SAMPLES = 64; SITES = 240
    for (site = 0; site < SITES; site++) freq[site] = 15 + next_random() % 31
    # A tiny marker panel otherwise gives chance KING outliers among 1,891 pairs, so
    # unrelated individuals are rejection-sampled with a conservative pairwise margin.
    for (sample = 0; sample < SAMPLES; sample++) {
        accepted = 0
        for (attempt = 0; attempt < 10000 && !accepted; attempt++) {
            for (site = 0; site < SITES; site++) {
                left = (next_random() % 100) < freq[site]
                right = (next_random() % 100) < freq[site]
                candidate[site] = left + right
            }
            accepted = 1
            if (sample < 61) {
                for (previous = 0; previous < sample; previous++) {
                    het_both = 0; opposite = 0; het_first = 0; het_second = 0
                    for (site = 11; site < SITES; site++) {
                        a = candidate[site]; b = gt[previous, site]
                        if (a == 1) het_first++
                        if (b == 1) het_second++
                        if (a == 1 && b == 1) het_both++
                        if (abs(a - b) == 2) opposite++
                    }
                    if (het_both - 2 * opposite > 0.035 * 2 * min(het_first, het_second)) { accepted = 0; break }
                }
            }
        }
        if (!accepted) { print "Could not construct deterministic unrelated fixture" > "/dev/stderr"; exit 1 }
        for (site = 0; site < SITES; site++) gt[sample, site] = candidate[site]
    }

    printf "##fileformat=VCFv4.3\n##contig=<ID=1,length=2000>\n##contig=<ID=X,length=2000>\n" > out
    printf "##FILTER=<ID=q10,Description=\"Low site quality\">\n" > out
    printf "##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">\n" > out
    printf "##FORMAT=<ID=DP,Number=1,Type=Integer,Description=\"Depth\">\n" > out
    printf "##FORMAT=<ID=GQ,Number=1,Type=Integer,Description=\"Genotype quality\">\n" > out
    printf "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT" > out
    for (sample = 0; sample < SAMPLES; sample++) printf "\tS%02d", sample > out
    printf "\n" > out
    split("all_missing half_missing monomorphic singleton low_dp low_gq partial_gt haploid_gt threshold_call ld_duplicate_a ld_duplicate_b", special, " ")
    split("0/0 0/1 1/1", code, " ")
    for (site = 0; site < SITES; site++) {
        for (sample = 0; sample < SAMPLES; sample++) calls[sample] = code[gt[sample, site] + 1] ":20:50"
        if (site == 0) for (sample = 0; sample < SAMPLES; sample++) calls[sample] = "./.:.:."
        if (site == 1) for (sample = 0; sample < 32; sample++) calls[sample] = "./.:.:."
        if (site == 2 || site == 3) {
            for (sample = 0; sample < SAMPLES; sample++) calls[sample] = "0/0:20:50"
            if (site == 3) calls[1] = "0/1:20:50"
        }
        if (site == 4) calls[2] = "0/1:9:50"
        if (site == 5) calls[3] = "0/1:20:19"
        if (site == 6) calls[4] = "0/.:20:50"
        if (site == 7) calls[5] = "1:20:50"
        if (site == 8) calls[6] = "0/1:10:20"
        calls[61] = calls[0]
        calls[62] = "./.:.:."
        if (site != 0) { split(calls[63], parts, ":"); calls[63] = parts[1] ":1:1" }
        if (site == 9) for (sample = 0; sample < SAMPLES; sample++) duplicate[sample] = calls[sample]
        if (site == 10) for (sample = 0; sample < SAMPLES; sample++) calls[sample] = duplicate[sample]
        id = site < 11 ? special[site + 1] : sprintf("locus%03d", site)
        printf "1\t%d\t%s\tA\t%s\t60\tPASS\t.\tGT:DP:GQ", (site + 1) * 5, id, site % 2 == 0 ? "C" : "G" > out
        for (sample = 0; sample < SAMPLES; sample++) printf "\t%s", calls[sample] > out
        printf "\n" > out
    }
    for (sample = 0; sample < SAMPLES; sample++) excluded[sample] = "0/1:20:50"
    excluded[62] = "./.:.:."; excluded[63] = "0/1:1:1"
    split("1\t1500\texcluded_indel\tA\tAC\t60\tPASS;1\t1505\texcluded_filter\tA\tG\t5\tq10;X\t100\texcluded_x\tA\tC\t60\tPASS", rows, ";")
    for (r = 1; r <= 3; r++) {
        printf "%s\t.\tGT:DP:GQ", rows[r] > out
        for (sample = 0; sample < SAMPLES; sample++) printf "\t%s", excluded[sample] > out
        printf "\n" > out
    }
}'

# Each contig is a single 2,000-byte line; ">1\n" occupies 3 bytes, the next header starts at 2004.
A2000=$(printf 'A%.0s' {1..2000})
printf '>1\n%s\n>X\n%s\n' "$A2000" "$A2000" >"$OUT/reference.fa"
printf '1\t2000\t3\t2000\t2001\nX\t2000\t2007\t2000\t2001\n' >"$OUT/reference.fa.fai"
{ printf 'sample\tpopulation\n'; for i in $(seq 0 63); do printf 'S%02d\t%s\n' "$i" "$([[ $(( i % 2 )) == 0 ]] && echo A || echo B)"; done; } >"$OUT/samples.tsv"

# Deliberate facts specified independently of downstream tool calculations.
cat >"$OUT/expected.json" <<'EOF'
{
  "schema_version": 1,
  "synthetic_only": true,
  "seed": 1729,
  "sample_count": 64,
  "input_records": 243,
  "input_eligible_biallelic_autosomal_pass_snps": 240,
  "mask_thresholds": { "min_dp": 10, "min_gq": 20 },
  "sample_missingness_threshold": 0.1,
  "site_missingness_threshold": 0.1,
  "expected_excluded_samples": ["S62", "S63"],
  "expected_retained_sample_count_before_relatedness": 62,
  "exact_duplicate_samples": ["S00", "S61"],
  "expected_site_missingness_exclusions": ["all_missing", "half_missing"],
  "expected_sites_after_sample_and_site_missingness": 238,
  "diversity_retains": ["monomorphic", "singleton"],
  "pca_maf_threshold": 0.05,
  "pca_maf_excludes": ["monomorphic", "singleton"],
  "special_sites": {
    "all_missing": { "position": 5, "missing_calls_after_mask": 64 },
    "half_missing": { "position": 10, "missing_calls_after_mask": 35 },
    "monomorphic": { "position": 15, "allele_count_after_mask": 0 },
    "singleton": { "position": 20, "allele_count_after_mask": 1, "allele_number_after_mask": 124, "carrier": "S01" },
    "low_dp": { "position": 25, "sample": "S02", "input_gt": "0/1", "expected_masked_gt": "./." },
    "low_gq": { "position": 30, "sample": "S03", "input_gt": "0/1", "expected_masked_gt": "./." },
    "partial_gt": { "position": 35, "sample": "S04", "input_gt": "0/.", "expected_masked_gt": "./." },
    "haploid_gt": { "position": 40, "sample": "S05", "input_gt": "1", "expected_masked_gt": "./." },
    "threshold_call": { "position": 45, "sample": "S06", "input_gt": "0/1", "expected_masked_gt": "0/1" }
  },
  "identical_genotype_loci": ["ld_duplicate_a", "ld_duplicate_b"],
  "excluded_input_records": ["excluded_indel", "excluded_filter", "excluded_x"],
  "notes": "Missingness and MAF expectations assume DP/GQ masking and diploid complete GT validation before filtering; relatedness pruning may retain either member of the duplicate pair. Population labels alternate independently of genotype generation. Unrelated synthetic individuals are rejection-sampled with a conservative pairwise margin to prevent chance kinship outliers in this tiny marker panel; this is a pipeline fixture, not estimator validation."
}
EOF
echo "Generated deterministic genotype fixtures: $OUT"
