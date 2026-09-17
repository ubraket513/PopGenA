#pragma once
#include "popgen.hpp"

namespace pg {
// Reads sorted BCF and writes a new BCF plus <output>.csi. Only autosomal,
// biallelic A/C/G/T SNPs with PASS or no FILTER are emitted. Complete diploid
// GTs retain phase; other calls and requested DP/GQ failures become ./..
// INFO AC/AN/AF/NS values are removed because masking invalidates them; other
// annotations are preserved and are not recalculated. Existing outputs are
// never replaced. Failed attempts may retain an unpublished staging directory.
json mask_genotypes(const fs::path& input, const fs::path& output,
                    int min_dp, int min_gq);
}
