# PopGenA — native Linux C++ population genomics

Continuing development in a new agent/session? Read [HANDOFF.md](HANDOFF.md)
for the current state, evidence, remaining work and resume commands.

PopGenA provides streaming VCF/BCF statistics, resumable native workflows, an
offline-validated genotype QC, relatedness, LD-pruning and PCA path, and a
paired-FASTQ-to-genotype workflow. It is a C++20 command-line program for
x86-64 Linux (developed on WSL2, Ubuntu 26.04, GCC 15).

## Build and run

```bash
make            # build every native dependency from vendored sources, then build/popgen
make check      # unit tests + all offline integration suites
make run        # tiny offline fixture -> out/demo
make doctor     # dependency versions and tool resolution
make plan       # review the offline BCF conversion -> statistics workflow
make workflow   # execute/resume that workflow
make genotype   # execute/resume the 15-task synthetic QC/PCA workflow (genotype-plan to review)
make reads      # execute/resume the 40-task synthetic FASTQ workflow (reads-plan to review)
make benchmark  # streaming statistics benchmark (SAMPLES=, SITES=)
make help       # every target
```

A single `make` works offline. Pinned upstream **source archives** for every
external tool live in `third_party/src/` (checked against `SHA256SUMS`) and are
built into the ignored `.deps/linux/` directory: HTSlib, bcftools and samtools
1.24; PLINK 2.0 a.7.6 with OpenBLAS; fastp 1.3.3 with ISA-L, libdeflate and
Highway; Bowtie2 2.5.5; Ninja; jq. The first build takes several minutes; later
builds only redo what changed. Nothing is downloaded, and no command above
downloads sequencing data.

System prerequisites: `gcc`/`g++` with C++20, GNU `make`, `perl`, and the zlib,
bzip2, liblzma and OpenSSL development headers (Debian/Ubuntu:
`build-essential zlib1g-dev libbz2-dev liblzma-dev libssl-dev`). No Python,
CMake, Julia or administrator-installed bioinformatics tools are needed.

`make clean` removes compilation outputs only; `make deps-clean` removes
`.deps/linux` (rebuilt by the next `make`). `work/` and `out/` hold data and
results and are never cleaned by the build.

Run the executable directly (or through the `./popgen` launcher):

```bash
build/popgen stats --input tests/fixtures/cohort.vcf \
  --samples tests/fixtures/samples.tsv --out out/my-analysis \
  --min-dp 10 --min-gq 20 --threads 2
```

`--samples` is optional; without it all samples belong to `ALL`. With metadata, a tab-delimited header containing `sample` and `population` is required, with exactly one row for every genotype sample. Row order may differ. Duplicate IDs, missing IDs, extra IDs, and empty population values are errors.

Results are written to a temporary sibling directory, validated and then renamed into place. Existing outputs are refused unless `--replace` is supplied. Replacement is restricted to a recognized, completed PopGenA result directory containing only the expected files. Old results remain intact if input parsing or analysis fails. As with a two-rename directory replacement, a hard process/power failure during publication may leave a `.popgen-backup-*` directory requiring recovery; do not delete it without inspecting it.

Progress/errors go to stderr, and the JSON result goes to stdout. Redistribution of built binaries requires preserving the dependencies' license obligations; see `third_party/NOTICE.md`.

## Results and scientific contract

- `samples.tsv`: called/heterozygous/alternate-allele counts, exclusion counts, observed heterozygosity and call rate.
- `sites.tsv`: per-record summaries, alternate-allele frequency and expected heterozygosity.
- `population_sites.tsv`: the same statistics for each metadata population at each eligible site.
- `populations.tsv`: pooled observed heterozygosity and mean per-site expected heterozygosity.
- `provenance.json`: input/metadata/output SHA256 hashes, software versions, options and record-selection counts.

See [scientific definitions](docs/STATISTICS.md) for exact denominators and selection policies. Memory use scales with samples and populations, rather than the full genotype matrix. Output size grows with eligible sites times populations. Input hashing currently adds one sequential read of the genotype file; this is not a content-addressed workflow cache.

## Status

See [validation scope and measured resources](docs/VALIDATION.md) and
[numerical backend choices](docs/NUMERICAL_BACKENDS.md) for the ALGLIB/PLINK2
assessment. A 100,000-person streaming statistics benchmark does not imply
100,000-person PCA support.

Build, statistics, workflows and the bounded genotype QC/PCA path are implemented; see [genotype configuration and scientific contract](docs/GENOTYPES.md) and [workflow execution and recovery](docs/WORKFLOWS.md). ENA discovery and size/checksum-verified acquisition are bash tools; see [acquisition](docs/ACQUISITION.md). Raw-read preprocessing, alignment and joint calling are implemented and tested on synthetic data; see [raw-read configuration](docs/READS.md). A bounded public 200-person genotype subset has passed QC/PCA and independent-count validation, and the Linux build reproduces the earlier Windows results exactly. Actual human FASTQ accuracy remains unvalidated; BWA is not installed. Remaining work is in [HANDOFF.md](HANDOFF.md) and [PLAN.md](PLAN.md).
