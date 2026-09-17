#pragma once
#include "popgen.hpp"
namespace pg {
json expand_reads(const json& config, const fs::path& base);
json check_fastq_pair(const fs::path& first, const fs::path& second);
json normalize_fastp_report(const fs::path& report, const fs::path& before, const json& after, const fs::path& output);
json prepare_reference(const fs::path& input, const fs::path& out, const std::string& expected, uint64_t max_bases);
json check_alignments(const std::vector<std::string>& files, const std::vector<std::string>& samples,
                      const std::vector<std::string>& libraries, const fs::path& reference, const fs::path& metadata,
                      const fs::path& out);
}
