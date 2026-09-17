# Numerical backend selection

Policy: reuse maintained scientific implementations; add C++ orchestration,
format adapters, resource controls and independent validation around them.
Do not replace established methods with bespoke numerical algorithms simply to
keep everything in one executable. Native command-line tools are valid backends.

| Operation | Current implementation | Next evaluation |
|---|---|---|
| VCF/BCF/BAM parsing and compression | HTSlib, zlib | Keep bounded streaming |
| Normalization and joint variant calling | bcftools | Real-read truth-set validation |
| Read QC / paired alignment | fastp / Bowtie2 | Actual human-read accuracy and resource limits |
| Sorting / mate repair / duplicate marking | samtools | Real-library validation |
| Genotype QC / LD / KING | PLINK2 | Genome-wide input; large-cohort pairwise costs |
| Bounded PCA | PLINK2 exact, mean imputation; LAPACK/BLAS from vendored OpenBLAS | PLINK2 randomized PCA benchmark and validation |
| PCA verification | Independent streamed covariance products | Subspace-aware checks for approximate methods |
| Diversity summaries | Explicit streamed count definitions | Reuse a defined established estimator for new FST features |

## ALGLIB assessment, 17 September 2026

ALGLIB is a legitimate C++ candidate. Its PCA interface provides full,
truncated and sparse variants. However, the performance charts on the linked
page describe particular older HPC configurations; they do not establish a
speed advantage over this project's native PLINK2 on these genotypes.
[PCA overview](https://www.alglib.net/dataanalysis/principalcomponentsanalysis.php).

The C++ Free Edition is GPL-2.0-or-later; it should not be described as simply
"non-commercial only". The commercial edition adds multithreading and optimized
backend options. The inspected free 4.08 source also contains SIMD intrinsic
kernels, so "free has no SIMD at all" would be inaccurate.
[Edition details](https://www.alglib.net/download.php),
[commercial features](https://www.alglib.net/commercial.php).

Source audit: official `alglib-4.08.0.cpp.gpl.zip`, SHA256
`0298826c8e6c0bdc24ac7d09a78aff127ea55cfbd6be42495462c9fa0ef5868a`.
Downloaded source remains in the ignored `.deps/alglib-audit` directory for
inspection; it is not linked into PopGenA or a new runtime requirement.
`dataanalysis.cpp`, `pcatruncatedsubspace`, allocates a full centered copy of its
dense input. Its public input is a dense `real_2d_array`. For 100,000 samples by
10,000 markers, float64 input is 8 GB; that copy adds another 8 GB before solver
workspace and the operating system. This convenience API is unsuitable for the
current 16 GB machine at that size. A general sparse matrix does not automatically
solve this: allele-frequency centering makes common-variant genotypes dense.

ALGLIB's lower-level out-of-core eigensolver could be considered with an explicit
streamed matrix-product adapter. That is a different integration from calling
the dense PCA function and still needs performance and convergence validation.
No ALGLIB runtime benchmark has been performed and no universal speed ranking
is claimed.

## Preferred next large-cohort PCA experiment

Evaluate native PLINK2 `--pca approx` first. It already consumes the project's
compressed genotypes and implements allele-frequency standardization and mean
imputation. Its documented primary memory formula predicts about 945.6 MB for
100,000 samples, 10,000 markers and 10 PCs, before other workspace. This is an
estimate, not a measured peak or permission to remove workflow limits.
[PLINK PCA documentation](https://www.cog-genomics.org/plink/2.0/strat).

Acceptance requires identical retained individuals, LD-pruned markers, allele
frequencies and missing-value handling; seed/provenance recording; exact versus
approximate eigenvalues and sign/subspace-invariant comparisons on bounded
inputs; then measured memory/time at increasing sizes. The current production
workflow remains exact with its 5,000-person gate until these checks pass.
Selection should follow genomic correctness, memory feasibility, measured speed,
Linux build-from-source support and licensing together, rather than a generic benchmark.
