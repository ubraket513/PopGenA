# PopGenA clean implementation plan

Prepared 2026-09-17 after inspecting the local references with Serena MCP.
Status: milestones 1–3 and the bounded genotype QC/PCA path of milestone 4 are implemented. Milestone 5 metadata discovery and bounded acquisition are implemented; native raw-read preprocessing/alignment/calling remain incomplete. Real-data validation/scaling remain planned.

## Implementation update

- Native Windows UCRT64 GCC, GNU Make and Ninja are installed project-locally from 47 version/hash-locked packages. HTSlib, bcftools and samtools 1.24 Windows binaries run successfully. These are pinned distribution builds; HTSlib was not rebuilt from source in this implementation.
- `make.ps1` enters the local toolchain environment without changing global PATH; Make delegates compilation to Ninja.
- The C++ CLI implements `stats`, `doctor`, `plan`, `run`, internal `step`, help/version and validation. Statistics stream VCF/BCF through HTSlib and publish TSV tables plus SHA256 provenance.
- Tests use independent hand-calculated goldens and actual native bcftools conversions. They cover missing/partial calls, unsupported ploidy, quality masking, all-missing sites, metadata identity, malformed/truncated input, Unicode paths, different caller directories, and guarded result replacement.
- Workflow execution uses a separate generated Ninja graph, native Windows pipelines with explicit handle inheritance, Job Objects, timeout/cancellation, committed-memory caps, and conservative pool/thread reservations. Plans do not execute commands or download data.
- Task specifications track source, executable, runtime DLL and optional reference identities. Successful output generations and failed attempts are retained separately; completion records validate output inventories and dependency generations before reuse. Routine large-file verification uses size/mtime, with full hashing available through `--verify-inputs`.
- The offline workflow converts VCF to BCF through actual bcftools processes and then computes statistics. Process/workflow tests cover upstream failure despite downstream success, argument quoting/Unicode, interruption/descendant cleanup, resume/invalidation, damaged outputs/manifests, pool scheduling and committed-memory limits.
- Milestone 4 now pins official native PLINK2 and expands a genotype config into 15 resumable tasks: normalization, masking, QC, explicit relatedness selection, PGEN/BCF+CSI, separate diversity/PCA marker sets, LD pruning, exact PCA and independent streamed eigenpair validation. Synthetic results: 61 retained samples, 238 diversity sites, 234 PCA markers. See `docs/GENOTYPES.md` for boundaries and numerical checks.
- `make.sh` and `popgen` provide tested Git Bash entry points alongside unchanged PowerShell usage. Linux remains separate.
- Milestone 5 now has ENA metadata discovery, explicit sample-to-individual/reference manifests, default plan-only acquisition, byte/disk budgets, streaming MD5/size verification and validated-file reuse. No biological downloads occurred. Official fastp/BWA native Windows binaries were not found in upstream install documentation; source ports/compatible native alternatives and the complete read-to-genotype path still require implementation/validation.
- No real sequencing data has been downloaded. `README.md`, `docs/STATISTICS.md` and `docs/WORKFLOWS.md` document the current executable's behavior.

## Location and scope

- Confirmed project root: `C:\PopGenA\PopGenA`.
- Initial development and execution target: native Windows. Linux will be developed separately later; WSL is not the initial runtime.
- Reference directories: `../population_genomics`, `../population_genomics_cpp`, and `../AntRepCLA`.
- The user's confirmed location supersedes the Linux implementation path in the old handoff.
- Build a C++20 application with Make as the user interface and Ninja as the build executor. No Python, Julia, CMake, or Nextflow dependency. Optional R figures.
- Support both public cohort genotypes and a raw-read path feeding the same genotype analysis boundary.
- Carry forward the handoff's 16 GB RAM / 8 cores / 500 GB free SSD profile, but measure actual available Windows resources before execution.

## Inspection findings

The clean directory was empty. The C++ reference contains `Makefile`, `build.ninja`, `tools/bootstrap.sh`, `src/popgen.hpp`, and `src/process.cpp`. The referenced main, statistics, workflow, and test translation units are missing. Its previous HTSlib build is historical evidence, not proof of a working application here.

The bootstrap selects a Linux x86_64 Ninja binary, and process execution uses POSIX fork/exec, pipes, signals, and waitpid. These cannot be carried into the Windows implementation unchanged. WSL availability was checked during inspection, but the user subsequently specified Windows-first development and a separate Linux counterpart later. The first Windows PATH probe found no g++, Make, or Ninja command; inspect installed compiler/tool locations before choosing or installing a toolchain.

Serena searches confirmed the Python pipeline's fixed pickle caching, numeric missing-code handling before PCA, exhaustive k=1..N clustering, caller-data mutation, and heterozygote counts without called-genotype denominators. Its outputs must not be frozen as scientific goldens.

The existing process helper is a behavioral sketch for a new Windows runner. It needs Windows process creation and argument quoting, inherited pipe-handle control, cancellation and process-tree cleanup, collision-safe temporary files, atomic publication, and tool resolution independent of the caller's working directory. Keep its interface separable so a Linux backend can be implemented later.

## What AntRepCLA actually uses

| Component | Local evidence | PopGenA decision |
|---|---|---|
| C++20 and OpenMP | Makefile and source | Reuse the approach; budget threads explicitly. |
| GNU Make | Direct compilation rules; no Ninja graph | Reuse target conventions, retain PopGenA's Make + Ninja requirement. |
| csv-parser 5.3.0 | README and `src/igblast.cpp` | Consider for metadata parsing only if justified; HTSlib handles VCF/BCF. |
| unordered_dense 5.0.1 | README and `src/types.hpp` | Add only if profiling demonstrates a relevant bottleneck. |
| doctest | Vendored header and tests | Suitable small test dependency; preserve license and pin identity. |
| IgBLAST 1.22.0 | Bundled executable and wrapper | Reuse external-tool/standard-format separation, not antibody algorithms. |
| Small custom logger and SVG writer | `src/log.*`, `src/svg.*` | Reuse stdout/stderr separation and simple logging conventions. |
| Optional R plotting | `tools/plot.R` and Make target | Keep figures separate from build, checks, and analysis. |
| Unit tests, frozen outputs, clean rebuild CI | Makefile and CI workflow | Adopt separate `test`, `verify`, and `check`; use new independent goldens and numerical tolerances. |

AntRepCLA's README says spdlog was removed; it does not currently rely on a graph library or Matplot++. Its offline-build claim does not transfer automatically to this project.

## Intended layout

```text
PopGenA/
  Makefile, build.ninja, README.md
  src/                 CLI, streaming statistics, config, task runner, workflow
  tests/               C++ tests, PowerShell integration checks, fixtures, goldens
  config/              offline demo and bounded variant/raw examples
  tools/               dependency bootstrap and optional R plotting
  third_party/         pinned dependencies and license notices
  docs/                scientific definitions, formats, decisions
  build/               generated compilation outputs
  work/                generated task graphs, manifests, stage state
  out/                 results, logs, provenance
```

Do not copy old Linux executables, object files, static libraries, generated configure state, or build caches into the new project. Reuse inspected source selectively and rebuild dependencies for Windows. Build cleanup must preserve inputs and analysis results.

## Ordered milestones and completion gates

### 1. Reproducible clean foundation

- Inventory native Windows compilers and build tools; select and validate a compatible C++20 toolchain, GNU Make, Windows Ninja, and OpenMP support. Evaluate MSVC/clang-cl versus a MinGW-w64 toolchain against actual dependency support before fixing the choice. A Windows executable/runtime is required; do not silently substitute WSL.
- Validate HTSlib's supported Windows build path and compression dependencies with a minimal VCF/BCF read test. If this is not viable under the chosen toolchain, report the concrete limitation and evaluate a supported native alternative before promising the same library architecture.
- Implement Windows dependency acquisition with PowerShell/native tools and Windows artifact hashes; replace Linux shell bootstrap assumptions. Use .exe outputs, correct compiler dependency tracking, and paths with spaces.
- Create Make/Ninja targets: build, bootstrap, test, verify, check, run, doctor, clean, help, and compilation database generation.
- Start from the handoff's CLI11, nlohmann/json, and HTSlib pins; verify source hashes, platform compatibility, licenses, and dependency build settings before reuse. Record a dependency manifest.
- Separate explicit dependency acquisition from offline application checks. Demo and test defaults must never fetch sequencing data.
- Add CLI help/version/error handling and diagnostics that clearly distinguish required core dependencies from optional workflow tools.

Gate: a pinned native Windows dependency setup produces the CLI .exe; incremental build does no unnecessary work; clean rebuild succeeds; the configured build never writes into reference directories or requires WSL.

### 2. Offline genotype statistics with independent answers

- Stream VCF/BCF through HTSlib. Validate sample IDs and population metadata, duplicate IDs, column requirements, and mapping independent of metadata row order.
- Initially support autosomal biallelic diploid SNPs with explicit contig mapping and transparent unsupported-record counts/errors.
- Define missing and partial-missing calls, DP/GQ masking, absent quality-field behavior, all-missing sites, and malformed-input behavior before coding.
- Emit sample/site/population TSV summaries with called counts and denominators. Define observed heterozygosity as heterozygous calls divided by eligible called diploid genotypes; document aggregation and expected-heterozygosity definitions separately.
- Add hand-calculable fixtures covering missingness, variable ploidy, multiallelic records, monomorphic sites, reordered metadata, and invalid inputs. Check equivalent VCF and BCF results.
- Record input identities, software versions, parameters, filtering counts, and output schema versions.

Gate: `make check` passes C++ and integration checks; `make run` produces deterministic small outputs offline. No golden is derived from the old buggy pipeline. Zero denominators produce documented missing values.

### 3. Safe, resumable workflow execution

- Implement config validation and reviewable `plan`, followed by explicit `run` and internal task execution.
- Keep the compile graph separate from generated analysis graphs; emit task JSON and Ninja dependencies in C++.
- Implement a native Windows subprocess backend with correctly encoded/quoted arguments, all pipeline exit statuses, controlled pipe inheritance, process-tree cancellation, handle cleanup, bounded termination, and clear failure logs. Evaluate Job Objects for child ownership. Test Unicode paths, spaces, and shell-special characters without routing arbitrary arguments through a shell.
- Use temporary stage outputs and publish success only after validation. Detect missing/corrupt outputs and incomplete prior attempts.
- Track effective config, input identities, tool versions, reference identity, and executable identity as dependencies. Use immutable large-input manifests/checksums without rehashing entire datasets on every invocation.
- Use one shared heavy-task pool plus bounded lightweight work; budget threads across all piped processes. Pools constrain concurrency, not actual memory consumption.

Gate: tests cover upstream failure with a successful final process, interruption, partial outputs, rerun without work, changed inputs/config/tools, launch from another directory, and paths containing spaces or shell-special characters. Planning performs no data downloads.

### 4. Standard genotype QC and population analysis

- Establish a Windows compatibility matrix for bcftools and PLINK2 before integrating them: supported distribution/build route, compiler/runtime requirements, licenses, and tiny-fixture execution. Pin validated Windows builds. Any unavailable tool is an explicit unresolved dependency, not permission to invoke Linux.
- Implement normalization and genotype masking, sample/site QC, BCF + CSI output, PGEN/PVAR/PSAM conversion, LD pruning, and configurable analysis PCs.
- Preserve sample identity, alleles, assembly and ploidy; keep the PCA marker set distinct from diversity-analysis inputs.
- Include relatedness assessment and an explicit retain/exclude policy before population interpretation.
- Compare numerical outputs with tolerances and PCA sign/subspace-aware checks. Keep population metadata separate from exploratory clusters.
- Add bounded optional clustering only after selecting a suitable native implementation and documenting the scientific purpose. Do not retain every k-means fit or generate dense individual-by-individual matrices.
- Treat FST as a separately defined, tested estimator; do not label differences in heterozygosity as population distance. Defer pi/dXY until callable/invariant-site denominators are available.

Gate: a tiny end-to-end genotype workflow produces validated QC reports, compressed genotypes and PC scores; repeat execution resumes correctly.

### 5. Acquisition and raw-read preprocessing

- Implement metadata discovery/manifests for the handoff's PRJEB31736 target. Verify collection, run/BioSample/individual mapping, paired layout, URLs, sizes, checksums, and exact reference compatibility at execution time.
- Audit native Windows availability/build feasibility for fastp, BWA-MEM, samtools, bcftools, and acquisition tools before committing to the raw-read implementation. Pin validated builds; evaluate scientifically appropriate native alternatives where necessary and document capability gaps. Do not assume every tool proposed in the Linux handoff works on Windows. Select reference FASTA and indexes by exact identity, not just the label GRCh38.
- Build acquisition -> read QC -> read-group-aware alignment -> paired-read fixmate/sorting/duplicate marking -> calling -> normalized genotype boundary.
- Combine multiple runs belonging to one person correctly. Use cohort calling or an explicitly supported reference-confidence strategy; never merge variant-only sample files by interpreting absent records as homozygous reference.
- First exercise connections on tiny reads/reference fixtures, then measure one real person at a time. Stream compatible stages and bound scratch usage.

Gate: tiny raw and variant input paths meet the same genotype contract; checksum failures, insufficient disk, failed stages, and reruns behave correctly. Real downloads require a reviewed size/resource manifest.

### 6. Real-data validation and measured scaling

- Begin with released genotypes for roughly 200–500 individuals and 10k–50k autosomal SNPs, with a documented selection procedure.
- Progress to the handoff's 2,504-person cohort after metadata/reference verification, using a suitable QC-filtered, LD-pruned marker set.
- Add C++ synthetic benchmarks up to 100k individuals, starting around 10k markers; record wall time, peak RSS, threads, scratch and output size.
- Target about 10–12 GB process memory on the handoff PC profile, adjusted to actual Windows availability. Avoid dense N x N matrices. Stop or reduce workload when measured budgets are exceeded.
- Add optional R plots, scientific definitions, troubleshooting, license notices, and native Windows CI clean-build/test/demo checks.

Gate: publish measured limits and validation scope. Synthetic scale tests do not establish biological correctness or feasibility of 100k raw WGS samples on a personal PC.

## First implementation slice

Complete the Windows toolchain and HTSlib feasibility gate first, then milestones 1 and 2 before installing the full analysis tool suite or downloading real sequence data. The first useful deliverable is a cleanly built Windows CLI plus an offline genotype fixture, independently verified TSV statistics, provenance, and repeatable checks. Linux implementation and validation are a separate later effort.

## Evidence and remaining decisions

- Primary scope: `../population_genomics_cpp/HANDOFF.md`.
- Inspected: both projects' build files, C++ declarations/process utilities, bootstrap, Python analysis patterns, AntRepCLA README/source includes/test layout/CI.
- Serena used project activation, source pattern searches and C++ symbol overviews. Activation created workspace-level `.serena` configuration.
- Context7 was queried for Ninja; its partial results were supplemented with the [official Ninja manual](https://ninja-build.org/manual.html), especially pools and dependency semantics.
- Before implementation, verify current documentation for each tool's exact invocation through Context7, with official documentation fallback.
- Still to select/validate: native raw-read preprocessing/alignment builds, real reference release/checksums and sample mapping, real-cohort QC thresholds, optional clustering, population differentiation estimator, and measured scaling. Compiler/core tools/PLINK2 are already pinned and validated on synthetic inputs.
- The original planning task performed no compilation or installation. Subsequent authorized implementation installed native project-local tools and ran builds/tests as described above; biological data downloads remain unperformed.
