#include "core/platform.hpp"
#include <fcntl.h>
#include <openssl/evp.h>
#include <sys/file.h>
#include <sys/random.h>
#include <unistd.h>
#include <array>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <memory>
#include <sstream>
#include <stdexcept>

namespace pg {
namespace {
std::string hex(const unsigned char* bytes, size_t size) {
    std::ostringstream out;
    for (size_t i = 0; i < size; ++i) out << std::hex << std::setw(2) << std::setfill('0') << int(bytes[i]);
    return out.str();
}
}

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

void throw_errno(const std::string& action) {
    throw std::runtime_error(action + ": " + std::strerror(errno));
}

UniqueFd::~UniqueFd() {
    if (fd_ >= 0) ::close(fd_);
}

UniqueFd& UniqueFd::operator=(UniqueFd&& other) noexcept {
    if (this != &other) {
        if (fd_ >= 0) ::close(fd_);
        fd_ = std::exchange(other.fd_, -1);
    }
    return *this;
}

FileLock exclusive_lock(const fs::path& path) {
    UniqueFd fd(::open(path.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0644));
    if (fd.get() < 0) throw_errno("Open lock " + utf8(path));
    if (::flock(fd.get(), LOCK_EX | LOCK_NB) != 0)
        throw std::runtime_error("Locked by another PopGenA process: " + utf8(path));
    return FileLock(std::move(fd));
}

void atomic_text(const fs::path& path, const std::string& content) {
    if (fs::is_regular_file(path) && read_text(path) == content) return;
    auto temp = path;
    temp += ".tmp-" + unique_id();
    try {
        UniqueFd fd(::open(temp.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644));
        if (fd.get() < 0) throw_errno("Create " + utf8(temp));
        for (size_t written = 0; written < content.size();) {
            auto n = ::write(fd.get(), content.data() + written, content.size() - written);
            if (n < 0) {
                if (errno == EINTR) continue;
                throw_errno("Write " + utf8(temp));
            }
            written += static_cast<size_t>(n);
        }
        if (::fsync(fd.get()) != 0) throw_errno("Flush " + utf8(temp));
        fs::rename(temp, path);
    } catch (...) {
        std::error_code ec;
        fs::remove(temp, ec);
        throw;
    }
}

void rename_no_replace(const fs::path& from, const fs::path& to) {
    if (::renameat2(AT_FDCWD, from.c_str(), AT_FDCWD, to.c_str(), RENAME_NOREPLACE) != 0)
        throw_errno("Cannot publish " + utf8(to));
}

json file_identity(const fs::path& path, bool full) {
    if (!fs::is_regular_file(path)) throw std::runtime_error("Required file missing: " + utf8(path));
    auto p = fs::canonical(path);
    auto size = fs::file_size(p);
    auto time = fs::last_write_time(p);
    json id = {{"path", utf8(p)}, {"size", size}, {"mtime", time.time_since_epoch().count()}};
    if (full || size <= 16 * 1024 * 1024) id["sha256"] = sha256(p);
    if (size != fs::file_size(p) || time != fs::last_write_time(p))
        throw std::runtime_error("File changed while identifying it: " + utf8(p));
    return id;
}
}
