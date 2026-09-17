#!/usr/bin/env bash
# Regenerate the deterministic synthetic paired-FASTQ fixture (tests/fixtures/reads):
# a 10 kb reference from a fixed 32-bit LCG, three samples with known genotypes at
# 1000/2000/3000, a same-library duplicate run, an independent library, a no-coverage
# site and one known low-quality pair per run.
set -euo pipefail
OUT=${1:-$(dirname -- "${BASH_SOURCE[0]}")/fixtures/reads}
mkdir -p -- "$OUT"

awk -v out="$OUT" '
function revcomp(s,   i, r) {
    r = ""
    for (i = length(s); i >= 1; i--) r = r comp[substr(s, i, 1)]
    return r
}
function repeat(c, n,   r) { r = ""; while (n-- > 0) r = r c; return r }
BEGIN {
    comp["A"] = "T"; comp["C"] = "G"; comp["G"] = "C"; comp["T"] = "A"
    bases = "ACGT"; state = 1729; ref = ""
    for (i = 0; i < 10000; i++) {
        state = (state * 1664525 + 1013904223) % 4294967296
        ref = ref substr(bases, int(state / 16777216) % 4 + 1, 1)
    }
    printf ">1\n%s\n", ref > (out "/reference.fa")
    split("1000 2000 3000", variants, " ")
    for (v = 1; v <= 3; v++) alt[v] = substr(bases, index(bases, substr(ref, variants[v], 1)) % 4 + 1, 1)

    split("A_lane1 A_lane2 A_library2 B_lane1 C_lane1", runs, " ")
    split("A A A B C", run_sample, " ")
    truth["A"] = "0/0 0/1 1/1"; truth["B"] = "0/1 0/0 0/1"; truth["C"] = "1/1 ./. 0/0"
    quality = repeat("I", 150); low = repeat("!", 150)
    for (r = 1; r <= 5; r++) {
        id = runs[r]; sample = run_sample[r]; serial = 0
        split(truth[sample], genotypes, " ")
        r1 = out "/" id "_1.fastq"; r2 = out "/" id "_2.fastq"
        printf "" > r1; printf "" > r2
        for (v = 1; v <= 3; v++) {
            position = variants[v]
            genotype = genotypes[v]
            if (genotype == "./.") continue
            for (j = 0; j < 24; j++) {
                start = position - 110 + j
                first = substr(ref, start, 150)
                if (genotype == "1/1" || (genotype == "0/1" && j % 2 == 1))
                    first = substr(first, 1, position - start) alt[v] substr(first, position - start + 2)
                second = revcomp(substr(ref, start + 200, 150))
                name = id "_" (++serial)
                printf "@%s/1\n%s\n+\n%s\n", name, first, quality >> r1
                printf "@%s/2\n%s\n+\n%s\n", name, second, quality >> r2
            }
        }
        # Known low-quality pair, removed by fastp rather than used for calling.
        printf "@%s_lowq/1\n%s\n+\n%s\n", id, substr(ref, 4501, 150), low >> r1
        printf "@%s_lowq/2\n%s\n+\n%s\n", id, revcomp(substr(ref, 4701, 150)), low >> r2
        close(r1); close(r2)
    }
}'
printf 'sample\tpopulation\nC\tP2\nA\tP1\nB\tP1\n' >"$OUT/samples.tsv"
jq -n --arg sha "$(sha256sum -- "$OUT/reference.fa" | cut -d' ' -f1)" '{
    schema_version: 1, reference_sha256: $sha, samples: ["A", "B", "C"], runs: 5, libraries: 4,
    positions: [1000, 2000, 3000],
    genotypes: {A: ["0/0", "0/1", "1/1"], B: ["0/1", "0/0", "0/1"], C: ["1/1", "./.", "0/0"]},
    low_quality_pairs_per_run: 1, duplicate_pairs_same_library: 72,
    notes: "A_lane1/A_lane2 share a library and duplicate every fragment. A_library2 is an independent library and must not be deduplicated against A_lib1. C has no coverage at site 2000."}' >"$OUT/expected.json"
echo "Deterministic reads fixture: $OUT"
