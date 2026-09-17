# Windows validation scope and measurements

Windows readiness has separate gates: offline correctness, real-genotype
integration, real-read accuracy, resource measurements and release packaging.
Passing one does not imply the others. Linux is a separate implementation.

## Resource accounting

Every completed native task now records wall time, user/kernel CPU time,
process-tree peak committed bytes and cumulative I/O read/write transfer bytes.
These use Windows Job Object accounting and include pipeline children.
Peak committed memory is **not RSS/working set**. I/O counters include pipes and
cached operations; they are not physical disk traffic. Final retained file sizes
are reported separately and are not peak temporary disk usage.

The APIs are documented by Microsoft: [extended job information](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-jobobject_extended_limit_information)
and [job I/O accounting](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-jobobject_basic_and_io_accounting_information).
Task memory caps continue to apply to committed memory. A regression test checks
that a released 32 MiB allocation still appears in the completed job's peak and
that output writes appear in its I/O counters.

## Synthetic streaming benchmark, 17 September 2026

Measured on Windows 11 Home build 26200, Intel i7-1165G7, 4 physical cores /
8 logical processors and about 16 GiB installed memory. Timing is one run on
this host, with other development activity; it is not a cross-machine guarantee.

| Item | Measurement |
|---|---:|
| Individuals | 100,000 |
| SNPs | 10,000 |
| Genotype cells | 1,000,000,000 |
| Synthetic BCF generation | 191.488 s |
| Streaming statistics | 23.948 s |
| Statistics peak job committed memory | 46,845,952 bytes (44.7 MiB) |
| Generator peak job committed memory | 22,425,600 bytes (21.4 MiB) |
| Retained workflow files | 302,623,696 bytes |

The deterministic generator produces varied diploid hardcalls with approximately
1% missingness. Summed output counts match its recorded counts exactly:
989,998,328 called, 10,001,672 missing, 349,985,015 heterozygous and
649,987,587 alternate alleles. Generation keeps one genotype row in memory.
This tests statistics throughput and accounting, not biological realism,
raw-read processing, KING or PCA scalability. The exact PCA path still has a
5,000-sample gate; 100,000-person population analysis is not implemented.

Reproduce explicitly, outside the routine offline test suite:

```powershell
./make.ps1 validation-tools
powershell -NoProfile -ExecutionPolicy Bypass -File tools/benchmark.ps1 -Samples 100000 -Sites 10000
```

The default benchmark is only 1,000 by 1,000. Successful unchanged generations
are reused. Choose a different `-Out` for a new timing run. Reports live in
`work/benchmark-100000-10000/benchmark.json`; machine details are stored alongside
the measured run. No benchmark downloads biological data.

## Bounded public-genotype validation

The selected source is the NYGC 20201028 **3,202-sample** phased release, with
200 individuals selected from the original **2,504-sample** panel: the first
40 IDs in lexical order within each superpopulation. This is a deterministic
integration sample, not a representative population sampling design.

Sources and pins:

- [NYGC release manifest](https://ftp.1000genomes.ebi.ac.uk/vol1/ftp/data_collections/1000G_2504_high_coverage/working/20201028_3202_phased/phased-manifest_July2021.tsv): original file sizes/MD5s.
- [Original panel](https://ftp.1000genomes.ebi.ac.uk/vol1/ftp/release/20130502/integrated_call_samples_v3.20130502.ALL.panel): sample/population mapping, locally SHA256-pinned.
- [GRCh38 reference dictionary](https://ftp.1000genomes.ebi.ac.uk/vol1/ftp/technical/reference/GRCh38_reference_genome/GRCh38_full_analysis_set_plus_decoy_hla.dict): chromosome length and sequence MD5.
- [UCSC hg38 chromosome reference](https://hgdownload.soe.ucsc.edu/goldenPath/hg38/chromosomes/): smaller per-chromosome download, checked against both its published archive MD5 and the original dictionary's uppercase sequence MD5.

The helper requests only byte ranges selected by the original Tabix index for
chr21:15,000,000–16,000,000, plus header and EOF. The index's published MD5 is
verified. Exact HTTP ranges/lengths are checked, and each retained range gets a
SHA256. The original **whole VCF MD5 is not verified**, since the whole file is
not downloaded. HTSlib performs indexed reading and BGZF integrity checks.
The local `chr21.region-cache.vcf.gz` has unfilled regions: it is an intermediate
cache for this region only, never a complete source VCF for arbitrary querying.
Only the extracted `cohort.bcf` is a complete standalone genotype input.

The acquisition cap is 32 MB of genotype ranges plus a 12.71 MB reference archive
and small metadata, with a 4 GB free-disk reservation. Sources are HTTPS. Long
full-file transfers failed during development; no complete 496 MB VCF was
downloaded. Partial failed transfers may remain under the ignored work directory.

```powershell
./make.ps1 validation-tools
powershell -NoProfile -ExecutionPolicy Bypass -File tools/prepare-real-cohort.ps1
# The preceding command shows a plan without downloading.
powershell -NoProfile -ExecutionPolicy Bypass -File tools/prepare-real-cohort.ps1 -Download
./build/popgen.exe run --config work/real-validation/config.json
```

The selected phased release contains hardcalls; DP/GQ filtering is explicitly
disabled, not replaced with invented quality values. Relatedness is reported
with `retain` policy: one contiguous chromosome interval cannot establish
genome-wide pedigree or population structure. PCA is an integration/numerical
check only. Real FASTQ variant-call accuracy still requires an independently
benchmarked sample and suitable truth regions.

## Remaining release gates

- Complete and record the real-genotype QC/PCA run and independent counts.
- Validate real human FASTQ calling against an independent truth set; characterize
  reference/index, alignment, call accuracy and peak disk requirements.
- Measure a genome-wide, QC-reviewed 2,504-person cohort before claiming that scale.
- Implement and validate approximate large-cohort analyses if 100,000-person PCA
  is required. Optional clustering/FST/plots remain separate features.
- Execute the configured remote Windows CI and assemble license-complete release
  packaging before distributing binaries beyond this development workspace.
