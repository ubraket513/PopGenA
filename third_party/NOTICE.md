# Dependency records

Vendored source headers:

| Dependency | Version | SHA256 | License |
|---|---|---|---|
| CLI11 | 2.5.0 | `4bf0a9490aa7209176ccda70544f95413e594d2207cca33c9cd18ded189a63a6` | BSD-3-Clause, `licenses/CLI11-LICENSE` |
| nlohmann/json | 3.12.0 | `aaf127c04cb31c406e5b04a63f1ae89369fccde6d8fa7cdda1ed4f32dfc5de63` | MIT, `licenses/json-LICENSE.MIT` |
| doctest | 2.5.0 | `a58efc9446d70ddd5dd3b7724ebb8742882860f36f46da64d62993b02911fb6f` | MIT and embedded notices, `licenses/doctest-LICENSE.txt` |

CLI11 and JSON headers were verified against the handoff's upstream pins. The doctest header was reused from the AntRepCLA project with its notices intact. License texts were obtained from their matching upstream tags.

Vendored upstream source archives (`third_party/src/`, pinned by `SHA256SUMS`)
are built by `make` into the ignored `.deps/linux/` directory. Each archive is an
unmodified upstream release (or, for PLINK 2, a GitHub archive of the pinned
commit) and contains its own license text.

| Dependency | Version | Source | License |
|---|---|---|---|
| HTSlib | 1.24 | samtools/htslib release | MIT/Expat; bundled cram/ code has its own BSD-style terms |
| bcftools | 1.24 | samtools/bcftools release | MIT/Expat or GPL (GPL applies only when built with GSL; not used here) |
| samtools | 1.24 | samtools/samtools release | MIT/Expat |
| PLINK 2 | v2.0.0-a.7.6, commit `1c68b8c` (`alpha7_patch`) | chrchang/plink-ng | GPL-3.0-or-later; bundled zstd/libdeflate/SFMT notices |
| OpenBLAS | 0.3.34 | OpenMathLib/OpenBLAS release | BSD-3-Clause (includes reference LAPACK, BSD-style) |
| fastp | 1.3.3 | OpenGene/fastp tag | MIT |
| ISA-L | 2.31.0 | intel/isa-l tag | BSD-3-Clause |
| libdeflate | 1.26 | ebiggers/libdeflate tag | MIT |
| Highway | 1.4.0 | google/highway tag | Apache-2.0 or BSD-3-Clause |
| NASM | 3.02 | nasm.us release (build-time assembler only) | BSD-2-Clause |
| Bowtie2 | 2.5.5 | BenLangmead/bowtie2 tag | GPL-3.0-or-later |
| Ninja | 1.13.2 | ninja-build/ninja tag | Apache-2.0 |
| jq | 1.8.1 | jqlang/jq release | MIT; bundled Oniguruma BSD-2-Clause and decNumber ICU license |

These dependencies have different license terms and this project does not
relicense them. The built `.deps/linux/` tree is a development output, not a
license-complete release package. Before redistributing binaries, assemble the
applicable notices and GPL source obligations for the shipped set; the matching
sources are the archives above.

Historical Windows dependency records (MSYS2 packages, prebuilt PLINK2, Bowtie2 and
community fastp binaries) are in git history and the ignored
`work/windows-legacy.tar.gz` archive.
