# Dependency records

Vendored source headers:

| Dependency | Version | SHA256 | License |
|---|---|---|---|
| CLI11 | 2.5.0 | `4bf0a9490aa7209176ccda70544f95413e594d2207cca33c9cd18ded189a63a6` | BSD-3-Clause, `licenses/CLI11-LICENSE` |
| nlohmann/json | 3.12.0 | `aaf127c04cb31c406e5b04a63f1ae89369fccde6d8fa7cdda1ed4f32dfc5de63` | MIT, `licenses/json-LICENSE.MIT` |
| doctest | 2.5.0 | `a58efc9446d70ddd5dd3b7724ebb8742882860f36f46da64d62993b02911fb6f` | MIT and embedded notices, `licenses/doctest-LICENSE.txt` |

CLI11 and JSON headers were verified against the handoff's upstream pins. The doctest header was reused from the local AntRepCLA reference with its notices intact. License texts were obtained from their matching upstream tags.

The native Windows toolchain, HTSlib 1.24, bcftools 1.24, samtools 1.24 and their dependency closure are obtained from MSYS2's official UCRT64 repository. Exact archive URLs, versions, SHA256 hashes and package license identifiers are recorded in `tools/windows-packages.lock.json`. Extracted upstream notices are retained under `.deps/ucrt64/share/licenses/` and other package documentation directories.

PLINK2 is downloaded from its official Windows distribution, pinned by archive and executable SHA256 in `tools/plink2.lock.json`. It is GPL-3.0-or-later with separately licensed upstream components; see `docs/NATIVE_TOOLS.md` and the upstream developer/source links. Its binary is not committed or relicensed here.

These dependencies have different license terms; the toolchain includes GPL components and runtime exceptions, and other libraries carry their own notices. This source project does not relicense them. The locally assembled `build/` directory is a development output, not a license-complete release package. Before binary redistribution, assemble the applicable notices, source/source-offer obligations, and runtime exceptions for the actual shipped dependency set.
