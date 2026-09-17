#pragma once
#include "popgen.hpp"
#include <atomic>
#include <map>
#include <windows.h>

namespace pg {
// Move-only ownership for native handles, including partially constructed pipelines.
class WinHandle {
    HANDLE value_ = nullptr;
public:
    WinHandle() = default;
    explicit WinHandle(HANDLE h) : value_(h) {}
    ~WinHandle() { reset(); }
    WinHandle(const WinHandle&) = delete;
    WinHandle& operator=(const WinHandle&) = delete;
    WinHandle(WinHandle&& other) noexcept : value_(other.release()) {}
    WinHandle& operator=(WinHandle&& other) noexcept { if(this!=&other) { reset();value_=other.release(); } return *this; }
    HANDLE get() const { return value_; }
    explicit operator bool() const { return value_ && value_!=INVALID_HANDLE_VALUE; }
    HANDLE release() { auto h=value_;value_=nullptr;return h; }
    void reset(HANDLE h=nullptr) { if(*this) CloseHandle(value_);value_=h; }
};
struct Command {
    std::vector<std::string> argv;
    int threads=1;
};
struct ProcessOptions {
    fs::path cwd, stdout_file, stderr_file;
    uint64_t timeout_ms=0, memory_mb=0;
    const std::atomic_bool* cancel=nullptr;
};
struct ProcessResult {
    std::vector<uint32_t> exit_codes;
    bool timed_out=false, cancelled=false;
    uint64_t elapsed_ms=0;
    uint64_t peak_job_committed_bytes=0, cpu_user_ms=0, cpu_kernel_ms=0;
    uint64_t io_read_bytes=0, io_write_bytes=0;
    bool success() const;
    json record() const;
};
fs::path executable_path();
fs::path resolve_executable(const std::string& name,const fs::path& base);
std::wstring quote_windows(const std::wstring& argument);
std::string ninja_path(const std::string& path);
ProcessResult run_pipeline(const std::vector<Command>& commands,const ProcessOptions& options);
void install_cancellation_handler();
bool cancellation_requested();
WinHandle exclusive_lock(const fs::path& path);
void atomic_text(const fs::path& path,const std::string& content);
json file_identity(const fs::path& path,bool full=false);
json plan_workflow(const fs::path& config,bool verify=false);
json run_workflow(const fs::path& config,bool verify=false);
json execute_task(const fs::path& task_file);
}
