#include "popgen.hpp"
#include "workflow.hpp"
#include <htslib/hts.h>
#include <openssl/evp.h>
#include <fcntl.h>
#include <sys/random.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <array>
#include <fstream>
#include <iomanip>
#include <memory>
#include <sstream>
#include <stdexcept>
namespace pg {
std::string utf8(const fs::path& path) {
    auto bytes = path.u8string();
    return {reinterpret_cast<const char*>(bytes.data()), bytes.size()};
}
std::vector<std::string> arguments() {
    auto raw = read_text("/proc/self/cmdline");
    std::vector<std::string> result;
    for (size_t start = 0; start < raw.size();) {
        auto end = raw.find('\0', start);
        if (end == std::string::npos) end = raw.size();
        result.push_back(raw.substr(start, end - start));
        start = end + 1;
    }
    return result;
}
std::string read_text(const fs::path& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("Cannot read " + utf8(path));
    std::ostringstream data;
    data << in.rdbuf();
    if (in.bad()) throw std::runtime_error("Read failed: " + utf8(path));
    return data.str();
}
void write_text(const fs::path& path, const std::string& value) {
    std::ofstream out(path, std::ios::binary);
    out.exceptions(std::ios::failbit | std::ios::badbit);
    out << value;
    out.close();
}
void rename_no_replace(const fs::path& from, const fs::path& to) {
    if (::renameat2(AT_FDCWD, from.c_str(), AT_FDCWD, to.c_str(), RENAME_NOREPLACE) != 0)
        throw std::runtime_error("Cannot publish " + utf8(to) + ": " + std::strerror(errno));
}
namespace {
std::string hex(const unsigned char* bytes, size_t size) {
    std::ostringstream out;
    for (size_t i = 0; i < size; ++i) out << std::hex << std::setw(2) << std::setfill('0') << int(bytes[i]);
    return out.str();
}
}
std::string unique_id() {
    std::array<unsigned char, 16> bytes{};
    if (::getrandom(bytes.data(), bytes.size(), 0) != static_cast<ssize_t>(bytes.size()))
        throw std::runtime_error("Cannot generate temporary name");
    return hex(bytes.data(), bytes.size());
}
std::string sha256(const fs::path& path) {
    std::unique_ptr<EVP_MD_CTX, decltype(&EVP_MD_CTX_free)> context(EVP_MD_CTX_new(), EVP_MD_CTX_free);
    if (!context || EVP_DigestInit_ex(context.get(), EVP_sha256(), nullptr) != 1)
        throw std::runtime_error("Cannot initialize SHA256");
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("Cannot hash " + utf8(path));
    std::array<char, 65536> buffer{};
    while (in) {
        in.read(buffer.data(), buffer.size());
        if (EVP_DigestUpdate(context.get(), buffer.data(), static_cast<size_t>(in.gcount())) != 1)
            throw std::runtime_error("SHA256 update failed");
    }
    if (in.bad()) throw std::runtime_error("SHA256 read failed");
    std::array<unsigned char, EVP_MAX_MD_SIZE> digest{};
    unsigned int length = 0;
    if (EVP_DigestFinal_ex(context.get(), digest.data(), &length) != 1)
        throw std::runtime_error("SHA256 finish failed");
    return hex(digest.data(), length);
}
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
