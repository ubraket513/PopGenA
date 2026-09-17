#pragma once
// Linux platform primitives shared by every module: path/text I/O, hashing, unique names,
// advisory locks and atomic publication.
#include <cstdint>
#include <filesystem>
#include <string>
#include <utility>
#include <vector>
#include <json.hpp>

namespace pg {
namespace fs = std::filesystem;
using json = nlohmann::json;

inline constexpr const char* version = "0.4.0";

std::string utf8(const fs::path& path);
inline fs::path from_utf8(const std::string& s) {
    return fs::path(std::u8string(s.begin(), s.end()));
}
// Command-line arguments exactly as received (from /proc/self/cmdline).
std::vector<std::string> arguments();
std::string read_text(const fs::path& path);
void write_text(const fs::path& path, const std::string& value);
std::string sha256(const fs::path& path);
std::string unique_id();
[[noreturn]] void throw_errno(const std::string& action);

// Owns a file descriptor; closes it on destruction.
class UniqueFd {
    int fd_ = -1;

public:
    UniqueFd() = default;
    explicit UniqueFd(int fd) : fd_(fd) {}
    ~UniqueFd();
    UniqueFd(const UniqueFd&) = delete;
    UniqueFd& operator=(const UniqueFd&) = delete;
    UniqueFd(UniqueFd&& other) noexcept : fd_(std::exchange(other.fd_, -1)) {}
    UniqueFd& operator=(UniqueFd&& other) noexcept;
    int get() const { return fd_; }
};

// Holds an advisory flock(2) for its lifetime; the kernel releases it if the process dies.
class FileLock {
    UniqueFd fd_;

public:
    FileLock() = default;
    explicit FileLock(UniqueFd fd) : fd_(std::move(fd)) {}
};
FileLock exclusive_lock(const fs::path& path);

// Write to a temporary sibling, fsync, then rename over the target.
void atomic_text(const fs::path& path, const std::string& content);
// Atomic rename that fails instead of replacing an existing destination.
void rename_no_replace(const fs::path& from, const fs::path& to);
// Path, size and mtime; SHA256 as well when full or the file is at most 16 MiB.
json file_identity(const fs::path& path, bool full = false);
}
