# Start here

Read [HANDOFF.md](HANDOFF.md) before resuming implementation. It records the
current code, actual validation evidence, uncompleted work and commands.

The project root is **/home/dzk55/bioinformatics/PopGenA**, a Linux (WSL2) C++20
project built with GCC and GNU Make. `make` builds every external tool offline from
the pinned source archives in `third_party/src`, then `build/popgen`; `make check`
runs the unit and integration tests. Scripts are bash. The earlier Windows build
and the reference repositories are gone; do not reintroduce PowerShell or Windows
code paths. Preserve the dirty Git working tree and local data/results in `work/`, and do
not commit unless the user asks.

Layout: modular C++ in `src/{app,core,stats,workflow,genotype,reads,tools}`, tests in
`tests/{unit,helpers,integration,generators,data}`, bash tools in
`scripts/{acquisition,validation,benchmark,lib,sources}`. Keep `make format-check` and
`make lint` clean (clang-format 21.1.8, shellcheck 0.11.0 — see README Development).

Use Serena MCP for targeted code inspection and editing, and Context7 for current
library/API/CLI documentation. Prefer established scientific libraries and native
tools; see `docs/NUMERICAL_BACKENDS.md` for the ALGLIB/PLINK2 decision.

Do not claim genome-wide or indel read accuracy, complete profiling or large-cohort PCA: see the
remaining gates and measurement limits in `HANDOFF.md` and `docs/VALIDATION.md`.
