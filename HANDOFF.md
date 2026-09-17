# PopGenA — handoff for Claude

Updated: 2026-09-17 (Asia/Seoul), after the Linux migration. This is the current
implementation handoff.

## Read first: location and state

**Project root: `/home/dzk55/bioinformatics/PopGenA`**, Linux on WSL2 (Ubuntu
26.04.1, kernel 6.18 WSL2, GCC 15.2). The project was first built as a native
Windows program and migrated to Linux on 2026-09-17. The earlier nested layout
(`C:\PopGenA\PopGenA`) was flattened, and the reference repositories
(`population_genomics`, `population_genomics_cpp`, `AntRepCLA`) were deleted at
the user's request; they no longer exist.

State: one offline `make` builds every dependency from vendored sources and the
application; `make check` passes (11 unit test cases, 6 integration suites); the
bounded real public-genotype validation and the 100k-person streaming benchmark
were re-run on Linux and match the Windows evidence. **The product is not
finished**: real human FASTQ calling accuracy, function-level profiling,
large-cohort approximate PCA, genome-wide validation and release packaging
remain. Do not confuse the 100k-person statistics benchmark with 100k-person PCA.

Read next:

1. `docs/VALIDATION.md` — measurements, Linux reproduction evidence, remaining gates.
2. `docs/NUMERICAL_BACKENDS.md` — library reuse policy and ALGLIB assessment.
3. `docs/WORKFLOWS.md`, `docs/GENOTYPES.md`, `docs/READS.md`, `docs/ACQUISITION.md`.
4. `PLAN.md` — roadmap; its top section summarizes the migration, the rest is history.

## User constraints and decisions

- Linux (WSL2) only, bash/GNU tooling and GCC. PowerShell and Windows support were
  removed deliberately. A CLI is the product; no GUI was requested.
- **Single `make` installs everything, offline** (like the user's AntRepCLA repo,
  which commits its dependencies). Decision: commit pinned upstream *source*
  archives, not binaries, and build them with GCC (license-clean, CPU-optimized).
- C++20 primary. GNU Make builds; Ninja executes generated analysis graphs. No
  Python, Julia, CMake or Nextflow dependency. R is allowed for optional figures.
- Prefer established scientific libraries/tools over reinventing algorithms
  (PLINK2, HTSlib/bcftools/samtools, fastp, Bowtie2, OpenBLAS).
- Process execution was simplified by decision: no enforced memory caps and no I/O
  accounting on Linux. `memory_mb` is a planning reservation and tool flag input.
  Pipelines stay, because the reads workflow pipes Bowtie2/samtools/bcftools.
- Use Serena MCP for code reading/editing (project `PopGenA`, languages cpp and
  bash; relative paths `src/...`). Use Context7 for library/CLI documentation.
- Public human cohorts are the intended data. No whole-study or enormous WGS
  downloads without an explicit reviewed byte/scratch plan. No real FASTQ has
  been downloaded.
- Hardware: i7-1165G7, 4 cores / 8 threads. **Linux sees 7.6 GiB RAM** (WSL2
  default, host has ~16 GiB); raise `memory=` in `%UserProfile%\.wslconfig` before
  memory-heavy work. The workflow default `resources.memory_mb` (10240) exceeds it;
  set explicit budgets in configs.
- Communicate concise progress in Korean when the user writes Korean; the user
  prefers continued action over repeated confirmation. Do not infer authorization
  for purchases or publication.

## Repository and build

Git HEAD `07b8de7` (`migration to C++`), no remote. The working tree is dirty with
the whole migration; nothing has been committed in this session. Do not reset it.

```bash
make              # vendored deps (first time: several minutes) + build/popgen
make check        # unit tests, then integration suites sequentially
make doctor       # tool versions and resolution
make help         # all targets
```

System prerequisites: gcc/g++, make, perl, zlib/bzip2/liblzma/OpenSSL headers.

| Component | Pin | Build |
|---|---|---|
| HTSlib, bcftools, samtools | 1.24 release archives | configure; static libhts, libdeflate |
| PLINK 2 | v2.0.0-a.7.6, plink-ng `1c68b8c` (`alpha7_patch`) | `mk/plink2.mk` (parallel, upstream flags, AVX2) |
| OpenBLAS | 0.3.34 | single+double precision only, `NOFORTRAN C_LAPACK`, OpenMP, static |
| fastp | 1.3.3 | with ISA-L 2.31.0 (NASM 3.02), libdeflate 1.26, Highway 1.4.0 |
| Bowtie2 | 2.5.5 | `bowtie2-align-s` + `-v256` (auto AVX2 dispatch) + `bowtie2-build-s` |
| Ninja | 1.13.2 | POSIX source list compiled directly (no Python) |
| jq | 1.8.1 | builtin Oniguruma, static; used by tools and tests |

Archives and `SHA256SUMS` are in `third_party/src` (~69 MB); rules in `mk/deps.mk`
use one verification stamp per archive. Output goes to ignored `.deps/linux`
(`prefix/bin` holds the tools; `popgen` resolves bare tool names there first,
then PATH). Licenses: `third_party/NOTICE.md`. Header-only CLI11/json/doctest stay
in `third_party/` (`tools/headers.lock.json`).

Ignored local state: `.deps` (Linux build + `alglib-audit`), `.cache` (ALGLIB and
BWA source archives), `build`, `work`, `out`. `work/` holds validation evidence —
do not delete it. Windows-era files removed in the migration are archived in
`work/windows-legacy.tar.gz`; Windows demo work directories were moved to
`work/windows-legacy-demos/` (their ownership markers point at `C:\` paths).

## Implemented paths

### Foundation, statistics and workflow engine

- `src/stats.cpp`: streamed autosomal biallelic diploid SNP counts, sample/site/
  population TSVs, explicit missing/quality semantics and SHA256 provenance.
  Variant-only summaries are not callable-base nucleotide diversity or dXY.
- `src/process.cpp`, `src/workflow.hpp`: `run_pipeline` runs 1–16 commands in one
  process group via `fork`/`execve` (no shell, CLOEXEC descriptors, exec errors
  reported through a status pipe). Failure/timeout/cancel → SIGTERM to the group,
  SIGKILL after 5 s; leftover descendants are killed before publication.
  `PR_SET_PDEATHSIG` chain (runner → Ninja → `popgen step` → tool group) makes even
  SIGKILL of `popgen run` clean up everything (tested); the top-level runner itself
  does not follow its parent, so `nohup` background runs survive the shell. Locks are `flock`.
  Metadata writes are temp + `fsync` + rename. Records: per-stage exit codes,
  elapsed, user/system CPU, `max_rss_bytes` (largest single process via `wait4`,
  not a pipeline sum).
- `src/platform.cpp`: OpenSSL EVP SHA256, `getrandom` IDs, `/proc/self/cmdline`
  arguments, `rename_no_replace` (`renameat2 RENAME_NOREPLACE`), `doctor`.
- `src/workflow.cpp`: `plan` writes a reviewable graph without running tasks;
  `run` validates prior completions and executes/resumes through Ninja.
  Immutable result generations; `state/<task>.json` → current `result_dir`.
  Symlinks inside work/result trees are refused. Source/tool/config changes
  invalidate affected work; large inputs use size/mtime unless `--verify-inputs`.

### Genotype QC / PCA (15 tasks)

`src/genotype.cpp`, `src/genotype_mask.cpp`, `config/genotype-demo.json`:
normalize → mask → PLINK import/missingness → sample QC → site QC → KING →
explicit relatedness selection → retained PGEN + VCF.gz → BCF/CSI → LD pruning →
exact PCA → independent streamed covariance/eigenpair validation, plus statistics.

- Diversity and PCA marker sets are separate. Relatedness policy must be explicit.
- Exact PCA limited to 5,000 individuals; LD pruning requires ≥50. Approximate
  PCA is **not wired in**.
- `analysis.memory_mb` minimum 1152 MiB (PLINK2's 640 MiB workspace + 512 MiB
  reserve), enforced at planning; PLINK gets `--memory` = budget − 512.
- PLINK exports VCF.gz then bcftools writes BCF: the old Windows PLINK put CR in
  direct BCF sample IDs; the validated route was kept.

### Raw reads (40-task offline fixture)

`src/reads.cpp`, `config/reads-demo.json`: reference SHA256/index → strict paired
FASTQ validation → fastp → output QC → Bowtie2 read-group-aware alignment/name
sort → fixmate/coordinate sort → merge per sample/library → mark duplicates →
BAM/CSI audit → joint bcftools calling → normalization/masking → statistics.

- Fixture: five runs, three samples, four libraries, three SNP truths; same-library
  cross-run duplicates marked, independent library preserved, uncovered site `./.`.
- Paired four-line Phred+33 FASTQ (plain/gzip), small Bowtie2 index only, reference
  cap 3.9 Gb, ≤64 runs. Whole human WGS feasibility not established. Scratch
  reservation is a free-space estimate, not a quota.
- Adapters: BAM paths go to mpileup as argv; fastp 1.3.3 does not JSON-escape its
  command field, so reports keep `fastp.raw.json` and the adapter repairs only that
  value (Linux runs so far needed no repair).

### Tools and tests (bash)

- `tools/discover-ena.sh`, `tools/acquire.sh`: ENA metadata discovery and
  plan-first bounded paired FASTQ acquisition (HTTPS, no redirects, size/MD5,
  atomic publish). `POPGEN_ACQUIRE_CURL` is a test hook for an offline transport.
- `tools/prepare-real-cohort.sh` (plan by default; `--download`; `--reuse DIR`
  seeds the range cache with re-verification), `tools/report-real-validation.sh`,
  `tools/benchmark.sh`.
- `tests/lib.sh` + `integration.sh`, `workflow.sh`, `mask.sh`, `genotype.sh`,
  `acquisition.sh`, `reads.sh`; artifacts under `build/test-work/` (paths contain
  space, `&` and Hangul on purpose). `tests/genotype-fixture.sh` and
  `tests/reads-fixture.sh` regenerate fixtures byte-identically (reads
  `expected.json` semantically).
- `.github/workflows/linux.yml` exists but has **never run** (no remote).

## Measured results

### Public genotype validation — Windows, then reproduced on Linux

Source: NYGC **3,202-person** 20201028 phased release; 200 individuals = first 40
IDs lexically in each superpopulation of the original **2,504-person** panel.
Region chr21:15,000,000–16,000,000 GRCh38; 22,817 PASS biallelic SNPs; 127 PCA
markers; five PCs; relatedness `retain`; GT-only (DP/GQ thresholds zero).

| Run | 15-task time | Memory metric |
|---|---:|---:|
| Windows, 4096 MiB | 7.201 s | 4,046,352,384 B peak committed |
| Windows, 1152 MiB | 9.911 s | 953,372,672 B peak committed |
| Linux, 1152 MiB | 3.585 s | 42,315,776 B largest task RSS |

Linux inputs were rebuilt **offline** from the verified Windows range cache
(`--reuse work/real-validation`): same FASTA SHA256
`c218d98e3bf58fa3551c3f5f12bc829c798c42fd301f8ed6021c35aa231f39f8`, same
sequence MD5 `974dc7aec0b755b19f031418fdedf293`, identical BCF records/samples.
Statistics TSVs byte-identical; PCA eigenvalues, full eigenvectors and pruned
markers identical (Windows used CRLF); independent bcftools counts match all 200;
residuals ≤1.77e-6.

Artifacts: `work/real-validation/` (Windows run and range cache; its configs hold
`C:\` paths — do not resume them on Linux), `work/real-validation-linux/`
(`config.json`, `analysis/`, `report.json`, `resources.csv`). Compact copies:
`docs/validation/real-cohort-{4096m,1152m,linux-1152m}.json`, `machine.json`,
`machine-linux.json`. The whole source VCF MD5 was never verified (only ranges);
`chr21.region-cache.vcf.gz` is sparse — never use it as a complete VCF.

### Synthetic scale — statistics ONLY

100,000 × 10,000 (10⁹ genotype cells): Linux generation 103.9 s, statistics
16.8 s at 41.0 MiB RSS (Windows: 191.5 s / 23.9 s / 44.7 MiB committed); counts
match exactly. Evidence: `docs/validation/streaming-100k{,-linux}.json`,
`work/benchmark-linux-100000-10000/`. Not a KING/PCA/raw-read benchmark.

### Test status at handoff

From a clean state (`make deps-clean && make clean`), `make` finished offline in
737 s (no downloads in the log) and a second `make` did nothing. `make check`: 11
doctest cases / 97 assertions and all six integration suites passed (45 s),
including a test that a background `popgen run` survives its launching shell.
`make workflow|genotype|reads` each ran twice with full reuse (2/15/40).

## Profiling: still missing

Task-level wall/CPU/RSS is recorded. **Function-level CPU sampling/flamegraphs
have NOT been run.** Real FASTQ alignment/calling CPU, RSS, peak scratch and
accuracy have NOT been measured. Retained output sizes are not peak temporary disk.
On Linux, `perf` is the natural next tool once a real bottleneck is observed.

## ALGLIB and approximate PCA

ALGLIB 4.08.0 Free C++ source was only inspected (`.deps/alglib-audit`, archive
SHA256 `0298826c8e6c0bdc24ac7d09a78aff127ea55cfbd6be42495462c9fa0ef5868a`); not
linked or benchmarked. Its dense `pcatruncatedsubspace()` copies the centered
input (100k×10k float64 → 8 GB + 8 GB), unsuitable here. Free C++ is
GPL-2.0-or-later. Preferred next experiment: PLINK2 `--pca approx` with matched
inputs, recorded seeds and explicit accuracy/resource gates. Its ~945.6 MB
estimate for 100k/10k/10 PCs is not a measured guarantee. Keep the exact-PCA gate
until approximate mode is implemented and validated. See NUMERICAL_BACKENDS.md.

## Next work, in priority order

1. **Commit the migration** when the user asks (nothing is committed yet).
2. **Real human FASTQ validation and profiling.** One bounded public sample with
   an independent truth set/confident regions and the exact reference. Record
   bytes/checksums and scratch plan before acquisition (`tools/discover-ena.sh`,
   `tools/acquire.sh`). Validate against truth, not our own calls. Measure wall,
   CPU, RSS, peak scratch; profile hot functions only for observed bottlenecks.
   Check WSL2 memory first.
3. **Approximate PCA backend** (PLINK2 first) compared with exact PCA on identical
   bounded data; seeds, eigenvalues, sign/subspace invariance. Address KING's
   quadratic pair work before calling the genotype workflow scalable.
4. **Genome-wide 2,504-person cohort** run, CI on a remote, and license-complete
   release packaging.
5. Possible refinement: a planner warning when reservations exceed physical RAM.

All C++ was reformatted with `.clang-format` (behavior-neutral; `make check` and
the real-data comparison were re-run afterwards). `make format` re-applies it when
`clang-format` is available (e.g. `uvx clang-format`); it is not a build dependency.

Optional clustering, a defined/tested FST estimator, callable-site pi/dXY and R
figures are separate unimplemented features; confirm scope with the user.
Never label single-region PCA as population inference.

## Commands to resume safely

```bash
cd /home/dzk55/bioinformatics/PopGenA
git status --short
make && make doctor
make check

# Real-data validation on Linux (already prepared; reruns reuse all 15 tasks).
build/popgen run --config work/real-validation-linux/config.json
tools/report-real-validation.sh

# Synthetic demos and benchmark.
make workflow && make genotype && make reads
make benchmark SAMPLES=1000 SITES=1000

# Acquisition/preparation are plan-only unless --download is given.
tools/prepare-real-cohort.sh
```

Find artifacts via `state/<task>.json` → `result_dir`. Never guess an attempt
generation, use staging paths as outputs, or delete earlier successes to make a
failed run look clean.
