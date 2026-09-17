#pragma once
// Streaming VCF/BCF genotype statistics (see docs/STATISTICS.md for exact definitions).
#include "core/platform.hpp"

namespace pg {
struct StatsOptions {
    fs::path input, samples, out;
    int threads = 2, min_dp = 0, min_gq = 0;
    bool replace = false;
};

struct Counts {
    uint64_t called = 0, het = 0, alt = 0, missing = 0, filtered = 0, unsupported = 0;
    void add(const Counts& other);
};

// Decimal ratio text, or "NA" for a zero denominator.
std::string ratio(uint64_t numerator, uint64_t denominator);
// Exactly 1..22 or chr1..chr22.
bool autosome(const std::string& contig);
// Splits on tabs, keeping empty trailing fields.
std::vector<std::string> split_tsv(const std::string& line);
json stats(const StatsOptions& options);
}
