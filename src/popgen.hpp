#pragma once
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>
#include <json.hpp>
namespace pg {
namespace fs = std::filesystem;
using json = nlohmann::json;
inline constexpr const char* version = "0.4.0";
struct StatsOptions {
    fs::path input, samples, out;
    int threads = 2, min_dp = 0, min_gq = 0;
    bool replace = false;
};
struct Counts {
    uint64_t called = 0, het = 0, alt = 0, missing = 0, filtered = 0, unsupported = 0;
    void add(const Counts& other);
};
std::string utf8(const fs::path& path);
inline fs::path from_utf8(const std::string& s) {
    return fs::path(std::u8string(s.begin(), s.end()));
}
std::vector<std::string> arguments();
std::string read_text(const fs::path& path);
void write_text(const fs::path& path, const std::string& value);
// Atomic rename that fails instead of replacing an existing destination.
void rename_no_replace(const fs::path& from, const fs::path& to);
std::string sha256(const fs::path& path);
std::string unique_id();
std::string ratio(uint64_t numerator, uint64_t denominator);
bool autosome(const std::string& contig);
std::vector<std::string> split_tsv(const std::string& line);
json stats(const StatsOptions& options);
json doctor();
}
