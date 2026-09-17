#include "app/doctor.hpp"
#include "core/process.hpp"
#include <htslib/hts.h>

namespace pg {
json doctor() {
    json result = {
        {"application", "PopGenA"}, {"version", version}, {"platform", "linux-x86_64"}, {"htslib", hts_version()}};
    result["optional_tools"] = json::object();
    for (const auto* name :
         {"ninja", "bcftools", "samtools", "plink2", "fastp", "bowtie2-align-s", "bowtie2-build-s", "Rscript"}) {
        try {
            result["optional_tools"][name] = utf8(resolve_executable(name, fs::current_path()));
        } catch (const std::exception&) {
            result["optional_tools"][name] = nullptr;
        }
    }
    return result;
}
}
