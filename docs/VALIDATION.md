# Validation scope and measurements

Readiness has separate gates: offline correctness, real-genotype integration,
real-read accuracy, resource measurements and release packaging. Passing one
does not imply the others.

The project was developed first as a native Windows build and migrated to Linux
(WSL2) on 17 September 2026. The Windows measurements below remain as recorded
evidence; the Linux build re-ran the same checks and reproduced the scientific
results exactly (see [Linux reproduction](#linux-reproduction-of-the-windows-evidence)).

## Resource accounting (Linux)

Every completed task records wall time, user/system CPU time summed over its
pipeline, every stage's exit status, and `max_rss_bytes`: the peak resident set
size of the largest single process, including its waited-for descendants
(`wait4` rusage). It is **not** the sum across concurrently running pipeline
stages, and it is not a hard limit: `memory_mb` values are planning reservations
passed to tools as memory flags. I/O counters are not recorded on Linux. Final
retained file sizes are reported separately and are not peak temporary disk usage.

The Windows build recorded different metrics (Job Object peak *committed* bytes
and I/O transfer counters, with an enforced committed-memory cap). Do not compare
Windows committed bytes with Linux RSS as if they were the same quantity.

Machines: `docs/validation/machine.json` (Windows 11, i7-1165G7, 4 cores / 8
threads, ~16 GiB) and `docs/validation/machine-linux.json` (the same PC under
WSL2, Ubuntu 26.04, GCC 15.2, **7.6 GiB visible to Linux** by the WSL2 default;
raise it with `memory=` in `%UserProfile%\.wslconfig` before large runs).

## Synthetic streaming benchmark

Deterministic diploid hard calls with ~1% missingness; one timing run per
platform on a development machine, not a cross-machine guarantee.

| Item | Windows (committed memory) | Linux / WSL2 (RSS) |
|---|---:|---:|
| Individuals × SNPs | 100,000 × 10,000 | 100,000 × 10,000 |
| Synthetic BCF generation | 191.488 s | 103.862 s |
| Streaming statistics | 23.948 s | 16.806 s |
| Statistics peak memory | 46,845,952 B (44.7 MiB) | 43,012,096 B (41.0 MiB) |
| Generator peak memory | 22,425,600 B (21.4 MiB) | 23,527,424 B (22.4 MiB) |
| Retained workflow files | 302,623,696 B | 302,516,601 B |

Summed output counts match the generator's recorded counts exactly on both
platforms: 989,998,328 called, 10,001,672 missing, 349,985,015 heterozygous and
649,987,587 alternate alleles. Generation keeps one genotype row in memory.
This tests statistics throughput and accounting, not biological realism,
raw-read processing, KING or PCA scalability. The exact PCA path still has a
5,000-sample gate; 100,000-person population analysis is not implemented.

```bash
make benchmark SAMPLES=100000 SITES=10000   # default is 1000 x 1000
```

Unchanged generations are reused; use `scripts/benchmark/benchmark.sh --out DIR` for a new
timing run. Reports: `work/benchmark-linux-*/benchmark.json`; compact copies in
`docs/validation/streaming-100k.json` (Windows) and `streaming-100k-linux.json`.

## Bounded public-genotype validation

The selected source is the NYGC 20201028 **3,202-sample** phased release, with
200 individuals selected from the original **2,504-sample** panel: the first
40 IDs in lexical order within each superpopulation. This is a deterministic
integration sample, not a representative population sampling design.

Sources and pins (`scripts/sources/real-cohort.lock.json`):

- [NYGC release manifest](https://ftp.1000genomes.ebi.ac.uk/vol1/ftp/data_collections/1000G_2504_high_coverage/working/20201028_3202_phased/phased-manifest_July2021.tsv): original file sizes/MD5s.
- [Original panel](https://ftp.1000genomes.ebi.ac.uk/vol1/ftp/release/20130502/integrated_call_samples_v3.20130502.ALL.panel): sample/population mapping, locally SHA256-pinned.
- [GRCh38 reference dictionary](https://ftp.1000genomes.ebi.ac.uk/vol1/ftp/technical/reference/GRCh38_reference_genome/GRCh38_full_analysis_set_plus_decoy_hla.dict): chromosome length and sequence MD5.
- Original GRCh38 chromosome sequence is retrieved by FAI byte offsets and verified against the dictionary MD5. A UCSC hg38 alternative passed its archive checksum but had a different chromosome sequence MD5 and was rejected.

The helper requests only byte ranges selected by the original Tabix index for
chr21:15,000,000–16,000,000, plus header and EOF. The index's published MD5 is
verified. Exact HTTP ranges/lengths are checked, and each retained range gets a
SHA256. The original **whole VCF MD5 is not verified**, since the whole file is
not downloaded. HTSlib performs indexed reading and BGZF integrity checks.
The local `chr21.region-cache.vcf.gz` is sparse: it is an intermediate cache for
this region only, never a complete source VCF for arbitrary querying. Only the
extracted `cohort.bcf` is a complete standalone genotype input.

The acquisition cap is 32 MB of genotype ranges plus a 48 MB original-reference
range and small metadata, with a 4 GB free-disk reservation. Sources are HTTPS.

```bash
scripts/validation/prepare-real-cohort.sh                        # plan only, no download
scripts/validation/prepare-real-cohort.sh --download             # fetch missing verified ranges
scripts/validation/prepare-real-cohort.sh --download --reuse work/real-validation   # reuse an earlier cache offline
build/popgen run --config work/real-validation-linux/config.json
scripts/validation/report-real-validation.sh                     # independent bcftools counts + PCA check
```

The selected phased release contains hard calls; DP/GQ filtering is explicitly
disabled, not replaced with invented quality values. Relatedness is reported
with `retain` policy: one contiguous chromosome interval cannot establish
genome-wide pedigree or population structure. PCA is an integration/numerical
check only. Real FASTQ variant-call accuracy still requires an independently
benchmarked sample and suitable truth regions.

### Observed real-genotype result (Windows)

The 15-task run completed in 7.201 seconds for 200 samples and 22,817 PASS
biallelic SNPs with a 4096 MiB task budget (peak job commitment 4,046,352,384 B;
PLINK workspace reservations dominate). All 200 individuals remained under the
retain policy. LD/MAF selection left 127 PCA markers for five PCs. The largest
relative eigenpair residual was 1.77e-6 (limit 0.001). bcftools independently
reproduced every sample's called, missing, heterozygous and alternate-allele
counts. A second run with a 1152 MiB budget took 9.911 s at 953,372,672 B peak
commitment with identical TSVs and eigenvalues. A 1024 MiB attempt exposed
PLINK2's 640 MiB minimum workspace; with the 512 MiB reserve the planner now
rejects budgets below 1152 MiB. Compact evidence: `docs/validation/real-cohort-4096m.json`
and `real-cohort-1152m.json`.

### Linux reproduction of the Windows evidence

On 17 September 2026 `scripts/validation/prepare-real-cohort.sh --download --reuse work/real-validation`
rebuilt the inputs **without any network access** from the verified Windows range
cache (every chunk's SHA256 re-checked). It reproduced the prepared reference FASTA
SHA256 `c218d98e3bf58fa3551c3f5f12bc829c798c42fd301f8ed6021c35aa231f39f8`,
the sequence MD5 and 22,817 SNPs; `cohort.bcf` decodes to identical records and
samples (its header differs only in the bcftools command-line record).

The 15-task workflow with a 1152 MiB PLINK budget, using PLINK2 a.7.6 and
OpenBLAS built from source, completed in 3.585 s (2.87 s user CPU). Compared with
the Windows 1152 MiB run:

- `samples.tsv`, `sites.tsv`, `populations.tsv`, `population_sites.tsv`: byte-identical.
- PCA eigenvalues and full eigenvectors, and the LD-pruned marker list: identical
  (the Windows PLINK build wrote CRLF line endings).
- Independent bcftools per-sample counts matched all 200 individuals; PCA
  residuals ≤ 1.77e-6; largest task RSS 42,315,776 B.

Compact evidence: `docs/validation/real-cohort-linux-1152m.json`; full outputs in
`work/real-validation-linux/`.

## Real-read accuracy: GIAB HG002 (Linux, 2026-09-17)

Source pins: `scripts/sources/giab-hg002.lock.json`. Reads are the GIAB HG002
Illumina 2x250 novoalign BAM (131 GB; its `.bai` MD5 is verified against the GIAB
checksum list). Only the index-selected byte ranges for **chr20:10,000,000-12,000,000**
(80.5 MB) were fetched. Primary alignments overlapping the interval were collated into
**280,181 read pairs** (both mates overlapping; 410 singletons dropped, about 70x). The
reference is GRCh38 chr20 from the 1000 Genomes analysis set, verified against the
dictionary MD5 `b18e6c531b0bd70e949a7fc20859cb01`. Truth is the GIAB v4.2.1 benchmark
VCF and `noinconsistent` BED (SHA256 recorded; GIAB publishes no MD5 for these files).

```bash
scripts/validation/prepare-giab-reads.sh --download
build/popgen run --config work/giab-hg002/config.json
scripts/validation/evaluate-calls.sh --calls <mask result>/masked.bcf \
  --truth work/giab-hg002/truth/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz \
  --bed work/giab-hg002/truth/HG002_GRCh38_1_22_v4.2.1_benchmark_noinconsistent.bed \
  --region chr20:10000000-12000000 --margin 10000 --sample HG002 --out work/giab-hg002/evaluation-masked.json
```

The 14-task reads workflow (fastp, Bowtie2 `--very-sensitive` against chr20, samtools
fixmate/sort/markdup, `bcftools mpileup | call -m`, normalization, DP≥10/GQ≥20 mask)
took 308 s; Bowtie2 index 80 s, alignment 136 s (4 threads), largest task RSS 295 MB,
retained analysis 585 MB. Evaluation within 1,946,451 confident bases
(chr20:10,010,000-11,990,000, 10 kb margins because edge pairs are incomplete):

| SNP TP | FP | FN | Precision | Recall | F1 | Genotype concordance |
|---:|---:|---:|---:|---:|---:|---:|
| 2,541 | 8 | 7 | 0.99686 | 0.99725 | 0.99706 | 1.000 |

Two multi-allelic positions were excluded. The evaluator matches CHROM/POS/REF/ALT for
biallelic SNPs with unphased genotypes; comparing the truth set with itself gives
precision = recall = 1. It is **not** haplotype-aware and does not evaluate indels.

Limits: one sample and one 2 Mb interval; reads were selected from an existing
alignment and re-aligned to chr20 only (no off-target or paralog reads), so this is
optimistic relative to whole-genome calling. Evidence:
`docs/validation/giab-hg002-chr20.json`.

## Whole-chromosome scale: 1000 Genomes chr22, 2,504 people (Linux, 2026-09-17)

Source pins: `scripts/sources/1000g-chr22.lock.json`. The whole NYGC phased chr22 VCF
(520 MB) was downloaded as parallel verified 8 MiB ranges (the EBI server throttled a
single connection to ~30 KiB/s) and matched the release-manifest **whole-file MD5**
`aaf19d9c7ffcd86b34275899ddc898e7`. All 2,504 original-panel individuals and
**929,834** PASS biallelic SNPs were kept.

```bash
scripts/validation/prepare-1000g-chromosome.sh --download
build/popgen run --config work/1000g-chr22/config.json
scripts/validation/report-real-validation.sh --out work/1000g-chr22
```

The 15-task genotype workflow completed in 1,918 s on the 8-thread / 7.6 GiB WSL2
machine while other workloads were running; the PLINK2 `--bcf` import took 1,480 s and
dominates. Largest task RSS 1.08 GiB (1,160,273,920 B; PLINK retained PGEN/VCF export); normalize 60 s, mask 92 s,
statistics 76 s, KING 10.5 s, PCA 1.8 s; 7.2 GB retained. No sample failed missingness
QC. KING reported 465 pairs above 0.0884 under the `retain` policy (single-chromosome
estimates are noisy, so pairs are reported, not excluded). LD/MAF selection left 9,079
PCA markers; the 10 exact eigenpairs passed independent validation (largest relative
residual 2.25e-6; eigenvalues 244.2, 94.6, 30.4, ...). bcftools independently
reproduced the called/heterozygous/alternate/missing counts of all 2,504 individuals.
Evidence: `docs/validation/1000g-chr22-2504-linux.json`.

Function-level CPU sampling and real FASTQ memory/disk profiling have not yet been
performed. Do not describe these task-level measurements as a completed profile.

## Remaining release gates

- Extend real-read validation beyond one 2 Mb interval: whole-chromosome or
  genome-wide reads, indels with a haplotype-aware comparison, and peak scratch disk.
- Speed up genotype import for large cohorts (PLINK `--bcf` import dominated chr22).
- Measure a genome-wide, QC-reviewed 2,504-person cohort before claiming that scale
  (and give WSL2 enough memory first).
- Implement and validate approximate large-cohort analyses if 100,000-person PCA
  is required. Optional clustering/FST/plots remain separate features.
- Run the CI workflows (`.github/workflows/ci.yml`, `real-data.yml`) on a configured remote,
  and assemble license-complete release packaging before distributing binaries.
