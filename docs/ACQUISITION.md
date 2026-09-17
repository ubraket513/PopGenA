# ENA discovery and bounded acquisition

These bash tools prepare reviewed paired FASTQ inputs for milestone 5.
They do not perform trimming, alignment, calling, or population inference.
Discovery downloads metadata only. Acquisition defaults to a plan and requires
both an explicit byte budget and `--download` before fetching biological files.

```bash
# Metadata only; output must be a new directory.
tools/discover-ena.sh --out out/ena-metadata

# Inspect metadata.tsv and catalog.json, select runs, and provide an explicit mapping.
tools/discover-ena.sh --out out/ena-selected --run ERR3239276 \
  --mapping samples-to-individuals.tsv --reference-assembly GRCh38 \
  --reference-sha256 <SHA256-of-your-reference-FASTA>

# Review the plan. This creates no output directory and downloads no FASTQs.
tools/acquire.sh --manifest out/ena-selected/manifest.json \
  --out data/fastq --max-bytes 40000000000

# Fetch exactly the reviewed request when ready.
tools/acquire.sh --manifest out/ena-selected/manifest.json \
  --out data/fastq --max-bytes 40000000000 --download
```

The default study is PRJEB31736. `--run` (repeatable) restricts the executable manifest to
selected run accessions; without it all reported runs are selected. Byte budgets
cover the entire manifest, including already-present files. A single run can
already exceed 25 GB, so the examples are illustrative, not an instruction to
download a whole study. No large data is needed to run the offline tests.

The mapping TSV must contain `sample_accession` and `individual`, for example:

```text
sample_accession	individual
SAMN00797023	chosen_individual_id
```

Use the exact `sample_accession` in the report. `secondary_sample_accession` is
retained separately. The program never infers a person from a run, secondary
accession, or sample label. Duplicate sample mappings and different BioSamples
mapped to one individual are rejected; multiple runs belonging to the same
explicitly mapped sample are accepted. Reference assembly and FASTA SHA256 are
required provenance declarations; this tool does not download or validate that
reference FASTA itself.

Discovery accepts only PAIRED records with exactly two matching `_1.fastq.gz`
and `_2.fastq.gz` files, sizes and MD5s. Ambiguous records remain visible in the
catalog and prevent publication of an executable manifest. `metadata.tsv`
retains the complete fetched report; `catalog.json` contains selected records.
`-ReportPath` processes an existing TSV offline and records that source kind.

Acquisition allows only HTTPS on `ftp.sra.ebi.ac.uk`, with canonical ENA FASTQ
paths and no credentials, query, fragment, alternate port, or redirects. It
generates filenames from validated run and mate IDs, rejects symlinked paths,
checks request size and free disk space (plus a 64 MiB reserve), and downloads
one file at a time with a 1 MiB buffer. A file becomes visible under its final
name only after exact byte count and streaming MD5 verification and a same-folder
rename. Failed owned partial files are removed. Existing correct files are
verified and reused; existing corrupt files are preserved and cause failure.
Concurrent acquisition to one directory is excluded by a delete-on-close lock.
Crash-left `.part` files are ignored; partial byte-range resume is not supported.
Available disk space can change during a transfer; an I/O failure will leave no
new final file for that transfer. Completed earlier files remain reusable.

MD5 verifies ENA's published checksum and accidental corruption; it is not a
cryptographic provenance signature. There are no embedded credentials and no
network fallback to alternate hosts or protocols.

Run `bash tests/acquisition.sh` (part of `make check`)
for synthetic offline checks of manifests, mapping, budgets, checksum reuse,
corrupt-existing preservation and rejection before publication. A process-local
in-memory HTTP transport exercises the real downloader with correct, truncated,
oversized and checksum-mismatched bodies, and a redirect response. This does not
exercise a live multi-gigabyte transfer. The live ENA metadata response was
checked separately; no FASTQ files were downloaded during development.

The endpoint and `read_run` file-report semantics follow the
[official ENA file report documentation](https://ena-docs.readthedocs.io/en/latest/retrieval/programmatic-access/file-reports.html).
It exposes requested fields in the requested order, including file URLs, MD5s,
and sizes. The selected API is
`https://www.ebi.ac.uk/ena/portal/api/filereport`; paired file lists were also
checked against its PRJEB31736 metadata response.
