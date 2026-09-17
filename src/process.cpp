#include "workflow.hpp"
#include <fcntl.h>
#include <signal.h>
#include <sys/file.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
#include <algorithm>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string_view>
#include <thread>

extern char** environ;

namespace pg {
namespace {
volatile std::sig_atomic_t cancel_signal = 0;
void on_cancel(int signal) {
    cancel_signal = signal;
}

[[noreturn]] void sys_error(const std::string& action) {
    throw std::runtime_error(action + ": " + std::strerror(errno));
}
uint64_t to_ms(const timeval& t) {
    return static_cast<uint64_t>(t.tv_sec) * 1000 + static_cast<uint64_t>(t.tv_usec) / 1000;
}

class Fd {
    int fd_;

public:
    explicit Fd(int fd) : fd_(fd) {}
    ~Fd() {
        if (fd_ >= 0) ::close(fd_);
    }
    Fd(const Fd&) = delete;
    Fd& operator=(const Fd&) = delete;
    Fd(Fd&& other) noexcept : fd_(std::exchange(other.fd_, -1)) {}
    int get() const { return fd_; }
};
Fd open_output(const fs::path& path) {
    Fd fd(::open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644));
    if (fd.get() < 0) sys_error("Open process output " + utf8(path));
    return fd;
}
bool executable_file(const fs::path& path) {
    return fs::is_regular_file(path) && ::access(path.c_str(), X_OK) == 0;
}
// Child environment: inherited, with thread counts pinned and a stable locale.
std::vector<std::string> child_environment(int threads) {
    const std::map<std::string, std::string> overrides = {{"OMP_NUM_THREADS", std::to_string(threads)},
                                                          {"OPENBLAS_NUM_THREADS", "1"},
                                                          {"MKL_NUM_THREADS", "1"},
                                                          {"LC_ALL", "C"}};
    std::vector<std::string> result;
    for (char** entry = environ; *entry; ++entry) {
        std::string_view item(*entry);
        if (!overrides.contains(std::string(item.substr(0, item.find('='))))) result.emplace_back(item);
    }
    for (const auto& [key, value] : overrides) result.push_back(key + "=" + value);
    return result;
}
}

FileLock::~FileLock() {
    if (fd_ >= 0) ::close(fd_);
}
FileLock& FileLock::operator=(FileLock&& other) noexcept {
    if (this != &other) {
        if (fd_ >= 0) ::close(fd_);
        fd_ = std::exchange(other.fd_, -1);
    }
    return *this;
}

// SIGINT/SIGTERM/SIGHUP cancel the running pipeline, which then terminates its whole
// process group. Killing `popgen run` reaches everything through parent-death signals:
// Ninja (started by run_pipeline) gets SIGTERM, Ninja forwards it to each `popgen step`
// (which also follows its parent), and each step terminates its tool process group.
void install_cancellation_handler(bool follow_parent) {
    // Only processes started by PopGenA or Ninja follow their parent; a top-level `popgen run`
    // must survive its launching shell (for example under nohup).
    if (follow_parent && ::prctl(PR_SET_PDEATHSIG, SIGTERM) != 0) sys_error("Request parent-death signal");
    struct sigaction action{};
    action.sa_handler = on_cancel;
    sigemptyset(&action.sa_mask);
    for (int signal : {SIGINT, SIGTERM, SIGHUP})
        if (sigaction(signal, &action, nullptr) != 0) sys_error("Install cancellation handler");
}
bool cancellation_requested() {
    return cancel_signal != 0;
}

fs::path executable_path() {
    return fs::canonical("/proc/self/exe");
}

// Bare names resolve to the vendored tools first (.deps/linux/prefix/bin next to build/),
// then to PATH. Names containing a slash are paths relative to base.
fs::path resolve_executable(const std::string& name, const fs::path& base) {
    if (name.empty() || name.find('\0') != std::string::npos)
        throw std::runtime_error("Empty or invalid executable name");
    auto candidate = from_utf8(name);
    if (candidate.has_parent_path()) {
        candidate = candidate.is_absolute() ? candidate : base / candidate;
    } else {
        auto vendored =
            executable_path().parent_path().parent_path() / ".deps" / "linux" / "prefix" / "bin" / candidate;
        if (executable_file(vendored)) {
            candidate = vendored;
        } else {
            const char* path = std::getenv("PATH");
            std::string_view dirs = path ? path : "";
            bool found = false;
            for (size_t start = 0; start <= dirs.size() && !found;) {
                auto end = std::min(dirs.find(':', start), dirs.size());
                auto dir = dirs.substr(start, end - start);
                auto option = fs::path(dir.empty() ? "." : std::string(dir)) / candidate;
                if (executable_file(option)) {
                    candidate = option;
                    found = true;
                }
                start = end + 1;
            }
            if (!found) throw std::runtime_error("Executable not found: " + name);
        }
    }
    if (!executable_file(candidate)) throw std::runtime_error("Not an executable file: " + name);
    return fs::canonical(candidate);
}

bool ProcessResult::success() const {
    return !timed_out && !cancelled && !exit_codes.empty() &&
           std::all_of(exit_codes.begin(), exit_codes.end(), [](int c) { return c == 0; });
}
json ProcessResult::record() const {
    return {{"exit_codes", exit_codes},      {"timed_out", timed_out},     {"cancelled", cancelled},
            {"elapsed_ms", elapsed_ms},      {"cpu_user_ms", cpu_user_ms}, {"cpu_system_ms", cpu_system_ms},
            {"max_rss_bytes", max_rss_bytes}};
}

// Runs a pipeline (stdout of each command feeds the next) in one new process group.
// On timeout, cancellation or any stage failing, the whole group receives SIGTERM, then
// SIGKILL after a grace period. Descendants left behind by finished commands are killed
// before returning so they cannot touch published outputs.
ProcessResult run_pipeline(const std::vector<Command>& commands, const ProcessOptions& o) {
    if (commands.empty() || commands.size() > 16) throw std::runtime_error("Pipeline must contain 1..16 commands");
    auto cancel_requested = [&] { return cancellation_requested() || (o.cancel && o.cancel->load()); };
    if (cancel_requested()) {
        ProcessResult cancelled;
        cancelled.cancelled = true;
        return cancelled;
    }

    // Everything the children need is prepared before fork().
    struct Stage {
        std::vector<std::string> args, environment;
        std::vector<char*> argv, envp;
    };
    std::vector<Stage> stages(commands.size());
    for (size_t i = 0; i < commands.size(); ++i) {
        if (commands[i].argv.empty() || commands[i].threads < 1) throw std::runtime_error("Invalid command");
        auto& s = stages[i];
        s.args = commands[i].argv;
        s.args.front() = resolve_executable(s.args.front(), o.cwd).string();
        s.environment = child_environment(commands[i].threads);
        for (auto& a : s.args) s.argv.push_back(a.data());
        s.argv.push_back(nullptr);
        for (auto& e : s.environment) s.envp.push_back(e.data());
        s.envp.push_back(nullptr);
    }
    auto output = open_output(o.stdout_file), error = open_output(o.stderr_file);
    Fd null_input(::open("/dev/null", O_RDONLY | O_CLOEXEC));
    if (null_input.get() < 0) sys_error("Open /dev/null");

    auto start = std::chrono::steady_clock::now();
    auto elapsed = [&] {
        return static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count());
    };
    std::vector<pid_t> pids;
    pid_t group = 0, parent = ::getpid();
    auto kill_group = [&](int signal) {
        if (group > 0) ::kill(-group, signal);
    };
    auto reap_all = [&] {
        for (auto pid : pids) ::waitpid(pid, nullptr, 0);
    };
    try {
        int previous = -1; // read end feeding the next stage
        for (size_t i = 0; i < stages.size(); ++i) {
            int pipe_fds[2] = {-1, -1};
            bool last = i + 1 == stages.size();
            if (!last && ::pipe2(pipe_fds, O_CLOEXEC) != 0) sys_error("Create pipe");
            int report[2];
            if (::pipe2(report, O_CLOEXEC) != 0) sys_error("Create exec status pipe");
            pid_t pid = ::fork();
            if (pid < 0) sys_error("Fork");
            if (pid == 0) {
                // exec failures reach the parent as errno through the CLOEXEC status pipe.
                ::setpgid(0, group);
                // If this runner dies, even by SIGKILL, its commands receive SIGTERM
                // (see install_cancellation_handler for how that reaches their descendants).
                if (::prctl(PR_SET_PDEATHSIG, SIGTERM) != 0 || ::getppid() != parent) {
                    int e = errno ? errno : ESRCH;
                    [[maybe_unused]] auto n = ::write(report[1], &e, sizeof e);
                    ::_exit(127);
                }
                int in = previous >= 0 ? previous : null_input.get(), out = last ? output.get() : pipe_fds[1];
                if (::dup2(in, 0) < 0 || ::dup2(out, 1) < 0 || ::dup2(error.get(), 2) < 0 ||
                    ::chdir(o.cwd.c_str()) != 0) {
                    int e = errno;
                    [[maybe_unused]] auto n = ::write(report[1], &e, sizeof e);
                    ::_exit(127);
                }
                ::execve(stages[i].argv[0], stages[i].argv.data(), stages[i].envp.data());
                int e = errno;
                [[maybe_unused]] auto n = ::write(report[1], &e, sizeof e);
                ::_exit(127);
            }
            ::setpgid(pid, group ? group : pid);
            if (!group) group = pid;
            pids.push_back(pid);
            ::close(report[1]);
            if (previous >= 0) ::close(previous);
            if (!last) ::close(pipe_fds[1]);
            previous = last ? -1 : pipe_fds[0];
            int child_errno = 0;
            auto n = ::read(report[0], &child_errno, sizeof child_errno);
            ::close(report[0]);
            if (n == sizeof child_errno) {
                if (previous >= 0) ::close(previous);
                errno = child_errno;
                sys_error("Launch " + stages[i].args.front());
            }
        }

        ProcessResult result;
        result.exit_codes.assign(pids.size(), -1);
        std::vector<bool> done(pids.size(), false);
        size_t remaining = pids.size();
        bool signalled = false;
        uint64_t kill_at = 0;
        while (remaining) {
            for (size_t i = 0; i < pids.size(); ++i) {
                if (done[i]) continue;
                int status = 0;
                rusage usage{};
                pid_t r = ::wait4(pids[i], &status, WNOHANG, &usage);
                if (r < 0 && errno != EINTR) sys_error("Wait for " + stages[i].args.front());
                if (r != pids[i]) continue;
                done[i] = true;
                --remaining;
                result.exit_codes[i] = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
                result.cpu_user_ms += to_ms(usage.ru_utime);
                result.cpu_system_ms += to_ms(usage.ru_stime);
                result.max_rss_bytes = std::max(result.max_rss_bytes, static_cast<uint64_t>(usage.ru_maxrss) * 1024);
                if (result.exit_codes[i] != 0 && !signalled) {
                    kill_group(SIGTERM);
                    signalled = true;
                    kill_at = elapsed() + 5000;
                }
            }
            if (!remaining) break;
            if (!signalled) {
                result.cancelled = cancel_requested();
                result.timed_out = o.timeout_ms && elapsed() >= o.timeout_ms;
                if (result.cancelled || result.timed_out) {
                    kill_group(SIGTERM);
                    signalled = true;
                    kill_at = elapsed() + 5000;
                }
            } else if (elapsed() >= kill_at) {
                kill_group(SIGKILL);
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
        kill_group(SIGKILL); // descendants that outlived their parents
        result.elapsed_ms = elapsed();
        return result;
    } catch (...) {
        kill_group(SIGKILL);
        reap_all();
        throw;
    }
}

FileLock exclusive_lock(const fs::path& path) {
    int fd = ::open(path.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0) sys_error("Open lock " + utf8(path));
    FileLock lock(fd);
    if (::flock(fd, LOCK_EX | LOCK_NB) != 0)
        throw std::runtime_error("Locked by another PopGenA process: " + utf8(path));
    return lock;
}

// Write to a temporary sibling, flush it to disk, then rename over the target.
void atomic_text(const fs::path& path, const std::string& content) {
    if (fs::is_regular_file(path) && read_text(path) == content) return;
    auto temp = path;
    temp += ".tmp-" + unique_id();
    try {
        Fd fd(::open(temp.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644));
        if (fd.get() < 0) sys_error("Create " + utf8(temp));
        for (size_t written = 0; written < content.size();) {
            auto n = ::write(fd.get(), content.data() + written, content.size() - written);
            if (n < 0) {
                if (errno == EINTR) continue;
                sys_error("Write " + utf8(temp));
            }
            written += static_cast<size_t>(n);
        }
        if (::fsync(fd.get()) != 0) sys_error("Flush " + utf8(temp));
        fs::rename(temp, path);
    } catch (...) {
        std::error_code ec;
        fs::remove(temp, ec);
        throw;
    }
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
