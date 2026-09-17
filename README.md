# PopGenA — native Windows C++ population genomics

The implementation provides streaming VCF/BCF statistics, resumable native workflows, and an offline-validated genotype QC, relatedness, LD-pruning and PCA path. It runs as a native Windows x64 CLI with PowerShell and Git Bash entry points. Linux implementation is a separate future effort.

## Build and run

From PowerShell in this directory:

```powershell
./tools/bootstrap.ps1   # explicit one-time native tool/dependency download
./make.ps1              # GNU Make -> Ninja -> C++20 executable
./make.ps1 check        # C++ tests + independent golden/integration checks
./make.ps1 run          # tiny offline fixture -> out/demo
./make.ps1 doctor       # dependency report
./make.ps1 plan         # review offline BCF conversion -> statistics workflow
./make.ps1 workflow     # execute/resume that workflow
./make.ps1 genotype-plan # review offline QC/PCA workflow
./make.ps1 genotype      # execute/resume its 15 tasks
```

The launcher changes PATH only for its own process. No WSL, Python, Julia, CMake, administrator installation, or global environment change is required. Windows 10 version 1903 or newer (UTF-8 application code page), PowerShell, and a tar executable with Zstandard support are required. Bootstrap uses HTTPS and verifies every archive against `tools/windows-packages.lock.json`. The entire compiler and native dependency closure is project-local under `.deps/`; archives remain in `.cache/` for repeat setup. Allow several GB of disk space for the toolchain and cache.

Normal builds and checks are offline after bootstrap. No command above downloads sequencing data. `tools/resolve-dependencies.ps1` is a maintainer operation that deliberately refreshes the package lock; do not run it for ordinary builds. Native libraries are the pinned Windows distribution builds, not reused Linux artifacts.

`make.ps1` forwards arguments to native GNU Make, including `NPROC=2` and `OUT=out/another-demo`. If native Make is already configured with the dependency bin directory on PATH, the same Makefile targets work directly. `clean` removes compilation outputs while preserving data/results/dependencies. `compile-commands` exports editor metadata.

Run the executable directly from PowerShell:

```powershell
./build/popgen.exe stats --input tests/fixtures/cohort.vcf `
  --samples tests/fixtures/samples.tsv --out out/my-analysis `
  --min-dp 10 --min-gq 20 --threads 2
```

`--samples` is optional; without it all samples belong to `ALL`. With metadata, a tab-delimited header containing `sample` and `population` is required, with exactly one row for every genotype sample. Row order may differ. Duplicate IDs, missing IDs, extra IDs, and empty population values are errors.

Results are written to a temporary sibling directory, validated and then renamed into place. Existing outputs are refused unless `--replace` is supplied. Replacement is restricted to a recognized, completed PopGenA result directory containing only the expected files. Old results remain intact if input parsing or analysis fails. As with a two-rename directory replacement, a hard process/power failure during publication may leave a `.popgen-backup-*` directory requiring recovery; do not delete it without inspecting it.

Progress/errors go to stderr, and the JSON result goes to stdout. The binary includes its Windows runtime DLLs beside it in `build/`; keep those together when launching it outside the project. Redistribution requires preserving the native dependencies' license obligations; see `third_party/NOTICE.md`.

## Results and scientific contract

- `samples.tsv`: called/heterozygous/alternate-allele counts, exclusion counts, observed heterozygosity and call rate.
- `sites.tsv`: per-record summaries, alternate-allele frequency and expected heterozygosity.
- `population_sites.tsv`: the same statistics for each metadata population at each eligible site.
- `populations.tsv`: pooled observed heterozygosity and mean per-site expected heterozygosity.
- `provenance.json`: input/metadata/output SHA256 hashes, software versions, options and record-selection counts.

See [scientific definitions](docs/STATISTICS.md) for exact denominators and selection policies. Memory use scales with samples and populations, rather than the full genotype matrix. Output size grows with eligible sites times populations. Input hashing currently adds one sequential read of the genotype file; this is not a content-addressed workflow cache.

## Status

Build, statistics, workflows and the bounded genotype QC/PCA path are implemented. See [genotype configuration and scientific contract](docs/GENOTYPES.md), [workflow recovery](docs/WORKFLOWS.md), and [Git Bash entry points](docs/GIT_BASH.md). ENA discovery and size/checksum-verified acquisition are implemented as explicit PowerShell tools; see [acquisition](docs/ACQUISITION.md). Raw-read preprocessing/alignment/calling, optional figures and scaling remain planned in [PLAN.md](PLAN.md). Reference projects are not runtime dependencies.

HTSlib, bcftools, samtools and PLINK2 are pinned native Windows tools. Bootstrap verifies the additional PLINK2 archive and executable against `tools/plink2.lock.json`. The genotype demo is synthetic; no real human sequencing dataset has been downloaded or analyzed. Native fastp/BWA availability remains unresolved; see [tool audit](docs/NATIVE_TOOLS.md).
