# Native Windows paired-read workflow

The `reads` workflow runs fastp, Bowtie2, samtools and bcftools as native Windows
processes. It ends at a normalized, quality-masked autosomal SNP BCF plus CSI and
streaming statistics. It does not automatically run population QC or PCA.

## Offline example

After explicit `./tools/bootstrap.ps1`, run from the project directory:

```powershell
./make.ps1 reads-plan
./make.ps1 reads
./make.ps1 reads  # reuse all 40 tasks
```

Git Bash uses `bash ./make.sh reads`, or
`bash ./popgen run --config config/reads-demo.json`. These commands use only the
committed synthetic fixture. No sequencing data is downloaded.

For your own inputs, copy `config/reads-demo.json`, edit the paths and identities,
then use `popgen.exe plan --config PATH` followed by `run --config PATH`.
Relative input and work paths resolve against the configuration directory.

## Input contract and configuration

Required fields are `schema_version: 1`, `workflow_type: "reads"`, `work_dir`,
`assembly`, `reference`, `reference_sha256`, `runs` and `limits`.
The reference must be plain FASTA, identified by an exact lowercase SHA256.
The assembly label alone does not establish compatibility. The reference is
verified, copied and indexed inside a task generation; original inputs are kept.
Human autosomes `1` through `22`, optionally prefixed with `chr`, are selected.
Including both names for one autosome is rejected. Other contigs remain in the
alignment reference but are excluded from calling.

Each of 1–64 runs specifies `id`, `sample`, `library`, `read1`, `read2`.
IDs start with a letter and contain at most 64 letters, digits, dots, underscores
or hyphens. Run IDs are unique. A file cannot be reused as another run or mate.
Runs from the same physical library must share both sample and library identity;
independent libraries must have different library identities. Acquisition
metadata does not establish this mapping automatically.

Inputs are synchronized, four-line paired FASTQ, plain or gzip, with A/C/G/T/N
bases and declared Phred+33 qualities. Pair names, mate tags, record lengths,
record counts and gzip integrity are checked before and after trimming.
Read names must be unique within a run; global name uniqueness is not tracked.
Wrapped FASTQ, single-end, interleaved, long-read and non-Illumina workflows are
outside this implementation. Empty input or an empty trimmed pair fails.

Optional `samples` is a TSV with `sample` and `population` columns and exactly
one row per configured individual. Omission assigns population `ALL`.

| Processing option | Default | Meaning |
|---|---:|---|
| `threads` | 2 | Tool worker count, 1–4 |
| `memory_mb` | 6144 | Per-task process-tree committed-memory limit, 1024–10240 |
| `timeout_seconds` | 3600 | Per-task timeout |
| `min_length` | 35 | Minimum trimmed read length |
| `qualified_quality` | 20 | fastp quality threshold |
| `unqualified_percent` | 40 | Maximum percentage below that threshold |
| `trim_adapters` | true | Paired-read adapter trimming |
| `max_fragment` | 1000 | Maximum paired alignment fragment length |
| `min_mapping_quality` | 20 | Pileup mapping-quality threshold |
| `min_base_quality` | 20 | Pileup base-quality threshold |
| `max_depth` | 250 | Pileup per-input-file depth cap |

`qc.min_dp` defaults to 5 and must be at least 1; `qc.min_gq` defaults to 10.
Missing/insufficient DP or GQ masks GT. These are configurable defaults, not
validated thresholds for a particular real cohort. `resources` defaults to
8 threads and 10240 MB. Reservations include pipeline processes and fastp
coordinator threads, so worker count alone is not the required resource budget.
Unknown configuration keys are rejected.

`limits.input_bytes` caps combined FASTQ file sizes (maximum 500 GB).
`limits.reference_bases` caps reference sequence length (maximum 3.9 billion,
small Bowtie2 index only). `limits.scratch_bytes` reserves available disk at
planning time (64 MiB–500 GB), requiring at least
`12 * reference_file_bytes + 16 * FASTQ_file_bytes + 64 MiB`.
This estimate is not a filesystem quota or a guaranteed upper bound, especially
for highly compressed input. Old successful generations and failed attempts
remain on disk. Reference parsing can allocate one whole contig; process memory
limits still apply. Full human-reference feasibility has not been measured.

Optional `tools` overrides paths for `fastp`, `bowtie2`, `bowtie2-build`,
`samtools`, `bcftools`. Overrides require compatible native Windows builds and
revalidation; the supplied defaults are the versions in `NATIVE_TOOLS.md`.

## Processing and scientific boundary

1. Verify reference identity and paired FASTQ; build the small Bowtie2 index.
2. Trim/filter with fastp; preserve paired output and HTML/JSON QC reports.
   Poly-G trimming and fastp duplication evaluation are disabled; duplicate
   removal is not performed on FASTQ.
3. Align using Bowtie2 very-sensitive end-to-end paired alignment, with mixed
   and discordant pairing disabled. Each run gets RG ID, SM, LB and PL tags.
4. Name-sort, run fixmate, coordinate-sort; merge runs per sample/library and
   mark duplicates within each library. Independent libraries stay separate.
5. Audit read groups, reference dictionaries, sort order, EOF and CSI indexes.
   Every library must have at least one usable proper-pair alignment.
6. Jointly pile up all libraries and call diploid cohort variants with DP/AD/GQ.
   Duplicate-marked reads are excluded. Samples are identified through SM.
7. Normalize against the same reference, mask low-quality genotypes, retain
   eligible autosomal biallelic SNPs, and compute statistics.

Uncovered sample/site combinations remain missing; they are not inferred as
homozygous reference. The output is variant-only and does not supply callable
invariant-base denominators for nucleotide diversity or dXY. See STATISTICS.md.
Sex chromosomes, structural variants, recalibration and real-cohort accuracy
validation are outside this milestone.

## Outputs, recovery and genotype-analysis handoff

`work_dir/state/TASK.json` points to the current successful `result_dir` for each
task. Use that path, not a guessed generation or the staging path in command
history. Important artifacts are:

- `reference`: reference.fa, reference.fa.fai and reference.json.
- `rN-trim`: paired compressed reads, fastp.raw.json and fastp.html;
  `rN-trim-check`: validated fastp.json and reads.json.
- `libN-markdup`: alignment.bam, its CSI and duplicates.txt.
- `bams`: samples.tsv, alignments.json and bams.list (provenance).
- `call`: cohort.bcf and CSI; `mask`: masked.bcf, CSI and mask.json.
- `stats`: the documented sample/site/population tables and provenance.

For population QC/PCA, create a separate `genotypes` config as described in
GENOTYPES.md. Set `input` to the successful mask result's masked.bcf,
`reference` and `reference_index` to the prepared reference artifacts, `samples`
to the bams result's samples.tsv, and use the same assembly label. Choose a new
work directory and cohort-appropriate QC/analysis settings. The three-sample raw
fixture is deliberately too small for the genotype path's 50-sample LD gate.

Windows compatibility adapters are explicit: BAM paths are passed as native
arguments because this bcftools build does not decode UTF-8 BAM-list paths
correctly. Very long aggregate command lines can still exceed Windows limits;
keep work paths short. The original fastp report is retained because its final
command field may contain unescaped Windows paths. The adapter removes only
that invalid command value, validates paired counts and emits valid fastp.json
with a repair annotation. Exact argv remains in task attempt provenance.

See WORKFLOWS.md for failure logs, cancellation, integrity checks and recovery.
Changing mask thresholds reruns mask/statistics without repeating alignment or
calling. No automatic deletion of old generations is performed.

## Validation scope

`tests/reads.ps1` uses five runs, three individuals, four libraries and three
independently specified SNP truths. It checks all genotype/depth values,
cross-run duplicate marking, independent-library preservation, zero-coverage
missingness, one low-quality pair removed per run, metadata and CSI queries.
It also checks one/two-worker agreement, Unicode/space/ampersand paths, reuse,
selective invalidation, corrupted output recovery, wrong reference hashes,
malformed/truncated FASTQ and rejected budgets/configurations.
This establishes integration on synthetic inputs; real-data accuracy, wall time,
peak memory and disk limits remain to be measured separately.
