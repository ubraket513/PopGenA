#pragma once
#include "popgen.hpp"
#include <atomic>
#include <map>
#include <utility>

namespace pg {
// Holds an advisory flock(2) for its lifetime; the kernel releases it if the process dies.
class FileLock {
    int fd_ = -1;

public:
    FileLock() = default;
    explicit FileLock(int fd) : fd_(fd) {}
    ~FileLock();
    FileLock(const FileLock&) = delete;
    FileLock& operator=(const FileLock&) = delete;
    FileLock(FileLock&& other) noexcept : fd_(std::exchange(other.fd_, -1)) {}
    FileLock& operator=(FileLock&& other) noexcept;
};
struct Command {
    std::vector<std::string> argv;
    int threads = 1;
};
struct ProcessOptions {
    fs::path cwd, stdout_file, stderr_file;
    uint64_t timeout_ms = 0;
    const std::atomic_bool* cancel = nullptr; // in addition to SIGINT/SIGTERM/SIGHUP
};
struct ProcessResult {
    std::vector<int> exit_codes; // per command: exit status, or 128 + signal number
    bool timed_out = false, cancelled = false;
    uint64_t elapsed_ms = 0, cpu_user_ms = 0, cpu_system_ms = 0;
    uint64_t max_rss_bytes = 0; // largest single process, including its waited descendants
    bool success() const;
    json record() const;
};
fs::path executable_path();
fs::path resolve_executable(const std::string& name, const fs::path& base);
ProcessResult run_pipeline(const std::vector<Command>& commands, const ProcessOptions& options);
// SIGINT/SIGTERM/SIGHUP cancel running pipelines; follow_parent also cancels when the parent dies.
void install_cancellation_handler(bool follow_parent);
bool cancellation_requested();
FileLock exclusive_lock(const fs::path& path);
void atomic_text(const fs::path& path, const std::string& content);
json file_identity(const fs::path& path, bool full = false);
json plan_workflow(const fs::path& config, bool verify = false);
json run_workflow(const fs::path& config, bool verify = false);
json execute_task(const fs::path& task_file);
}
