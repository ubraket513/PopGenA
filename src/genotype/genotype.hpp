#pragma once
#include "core/platform.hpp"
namespace pg {
json expand_genotypes(const json& config, const fs::path& base);
json select_cohort(const fs::path& original, const fs::path& psam, const fs::path& kinship, const fs::path& metadata,
                   const fs::path& out, const std::string& policy, double threshold);
json validate_pca(const fs::path& psam, const fs::path& vectors, const fs::path& values, int pcs,
                  const fs::path& bcf = {}, const fs::path& markers = {});
}
