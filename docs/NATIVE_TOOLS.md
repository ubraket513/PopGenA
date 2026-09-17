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

The implemented path now uses fastp 1.3.3 from the community
[win-ngs Windows port](https://github.com/win-ngs/fastp-windows-build/releases/tag/v1.3.3-windows).
This is not an official OpenGene binary. Its UCRT64 executable and six runtime
DLLs are individually pinned, together with the ZIP hash, in
`tools/raw-tools.lock.json`. Source and build scripts are available from that
repository; upstream fastp is MIT licensed and bundled libraries have separate
terms. The archive does not contain a complete redistribution notice bundle.

Alignment uses the official
[Bowtie2 2.5.5 MinGW release](https://github.com/BenLangmead/bowtie2/releases/tag/v2.5.5).
The small-index native build/align executables and LICENSE are pinned. PopGenA
invokes them directly without the Perl wrappers. Bowtie2 is GPL-3.0-or-later.
This is an alternative aligner, not a claim of numerical equivalence to BWA.
BWA source portability was inspected but no native BWA build is installed.

`tools/bootstrap-raw.ps1` is also called by the main bootstrap. It checks archive
and installed-file SHA256 and repairs missing/damaged pinned members from the
verified archive. These are measured integrity pins, not publisher signatures.
Normal builds and workflows do not download tools. The raw executables ran
successfully on the synthetic integration fixture without WSL or an MSYS shell.
See READS.md for scientific limits and the Windows path/report adapters.