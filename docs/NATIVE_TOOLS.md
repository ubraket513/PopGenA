# Native Windows tool acquisition

PLINK2 is pinned in `tools/plink2.lock.json` to the official Windows 64-bit,
non-AVX2 archive dated 14 September 2026. The installed executable reports
`PLINK v2.0.0-a.7.6 64-bit (14 Sep 2026)`. It runs directly on Windows with no
MSYS shell or WSL dependency. This is an alpha release; pin changes require
rerunning the scientific integration fixtures.

Run `powershell -NoProfile -ExecutionPolicy Bypass -File tools/bootstrap-plink2.ps1`
from the project root to acquire it at `.deps/plink2/plink2.exe`. Acquisition is
explicit; ordinary workflow execution does not download tools. The bootstrap
verifies both archive and executable SHA256 and exact version output, and reuses
a verified cached archive. Hashes were measured from the downloaded official
archive; they are integrity pins, not an upstream signature verification.

The [official download page](https://www.cog-genomics.org/plink/2.0/)
distinguishes Windows 64-bit from Windows AVX2. The
[developer page](https://www.cog-genomics.org/plink/2.0/dev) states GPLv3-or-later
for PLINK2 and identifies separately licensed components. Source is available
from [plink-ng](https://github.com/chrchang/plink-ng). The upstream ZIP contains
`plink2.exe` and an unused `vcf_subset.exe`; the bootstrap installs only PLINK2.
Binary redistribution must satisfy upstream license obligations; this project
downloads the upstream archive instead of committing the executable.

## FASTQ preprocessing and alignment audit

As of 17 September 2026, the upstream
[fastp installation instructions](https://github.com/OpenGene/fastp#get-fastp)
offer a Linux binary and source builds. They do not advertise an official native
Windows executable. Current source-build dependencies include ISA-L, libdeflate,
and Highway. A native Windows build needs separate verification; installing Git
Bash does not make the published Linux binary executable on Windows.

The [BWA README availability section](https://github.com/lh3/bwa#availability)
describes source compilation using Make and zlib, and an x86_64-linux prebuilt
binary in bwakit. It does not advertise a native Windows binary. The
[BWA-MEM2 README](https://github.com/bwa-mem2/bwa-mem2#installation) also does not
provide a documented native Windows installation route. These findings concern
upstream installation documentation, not proof that community Windows ports
cannot exist.

Therefore, FASTQ-to-alignment execution must use a separately pinned and tested
native build or an explicitly configured compatible Windows executable. Until
one is verified, BAM/CRAM entry using the existing native samtools/bcftools
installation can be validated independently. Do not claim fastp or BWA-MEM is
installed based on a workflow template or command-presence check alone.
