#pragma once
// Tool resolution and pipeline execution with timeouts, cancellation and descendant cleanup.
#include "core/platform.hpp"
#include <atomic>

namespace pg {
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
// Bare names resolve to the vendored tools (.deps/linux/prefix/bin next to build/), then PATH;
// names containing a slash are paths relative to base.
fs::path resolve_executable(const std::string& name, const fs::path& base);
// Runs 1..16 commands connected stdout-to-stdin in one new process group.
ProcessResult run_pipeline(const std::vector<Command>& commands, const ProcessOptions& options);
// SIGINT/SIGTERM/SIGHUP cancel running pipelines; follow_parent also cancels when the parent dies.
void install_cancellation_handler(bool follow_parent);
bool cancellation_requested();
}
