#include "core/process.hpp"
#include <doctest.h>
#include <chrono>
#include <fstream>
#include <thread>

namespace {
struct ProcessFixture {
    pg::fs::path root = pg::fs::temp_directory_path() / pg::from_utf8("popgen-process-test-" + pg::unique_id());
    std::string helper = pg::utf8(pg::executable_path().parent_path() / "process-helper");
    ProcessFixture() { pg::fs::create_directory(root); }
    ~ProcessFixture() {
        std::error_code ec;
        pg::fs::remove_all(root, ec);
    }
    pg::ProcessOptions options(uint64_t timeout = 5000) const {
        return {root, root / "stdout.log", root / "stderr.log", timeout, nullptr};
    }
};
// True once pid no longer exists or is only an unreaped zombie.
bool gone(pid_t pid) {
    for (int i = 0; i < 50; ++i) {
        std::ifstream stat("/proc/" + std::to_string(pid) + "/stat");
        std::string line;
        if (!std::getline(stat, line)) return true;
        auto close = line.rfind(')');
        if (close != std::string::npos && close + 2 < line.size() && line[close + 2] == 'Z') return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    return false;
}
}
TEST_CASE("Argument passing preserves Unicode quotes empty strings and shell metacharacters") {
    ProcessFixture f;
    std::vector<std::string> values = {"",           "a b",      "trailing\\", "a\\\"b", "$&|<>%^!;`*",
                                       "\"quoted\"", "'single'", "샘플"};
    pg::Command command{{f.helper, "args"}, 3};
    command.argv.insert(command.argv.end(), values.begin(), values.end());
    auto result = pg::run_pipeline({command}, f.options());
    REQUIRE(result.success());
    CHECK(pg::json::parse(pg::read_text(f.root / "stdout.log")) == values);
    result = pg::run_pipeline({{{f.helper, "env"}, 3}}, f.options());
    REQUIRE(result.success());
    auto env = pg::json::parse(pg::read_text(f.root / "stdout.log"));
    CHECK(env["omp"] == "3");
    CHECK(env["blas"] == "1");
    CHECK(env["mkl"] == "1");
    CHECK(env["locale"] == "C");
}
TEST_CASE("Binary pipeline drains buffers and upstream failures cannot be hidden") {
    ProcessFixture f;
    auto result = pg::run_pipeline({{{f.helper, "emit", "262144"}, 1}, {{f.helper, "copy"}, 1}}, f.options());
    REQUIRE(result.success());
    CHECK(pg::fs::file_size(f.root / "stdout.log") == 262144);
    result = pg::run_pipeline({{{f.helper, "fail"}, 1}, {{f.helper, "copy"}, 1}}, f.options());
    CHECK_FALSE(result.success());
    CHECK(result.exit_codes[0] == 23);
    CHECK(result.exit_codes[1] == 0);
    result = pg::run_pipeline({{{f.helper, "fail"}, 1}, {{f.helper, "sleep", "30000"}, 1}}, f.options());
    CHECK_FALSE(result.success());
    CHECK(result.elapsed_ms < 5000);
}
TEST_CASE("Timeout and cancellation clean up process trees") {
    ProcessFixture f;
    auto pidfile = f.root / "descendant.pid";
    auto result = pg::run_pipeline({{{f.helper, "spawn", pg::utf8(pidfile)}, 1}}, f.options(500));
    CHECK(result.timed_out);
    CHECK_FALSE(result.success());
    REQUIRE(pg::fs::exists(pidfile));
    CHECK(gone(static_cast<pid_t>(std::stol(pg::read_text(pidfile)))));
    std::atomic_bool cancel{false};
    auto opts = f.options();
    opts.cancel = &cancel;
    std::jthread interrupt([&] {
        std::this_thread::sleep_for(std::chrono::milliseconds(150));
        cancel.store(true);
    });
    result = pg::run_pipeline({{{f.helper, "sleep", "30000"}, 1}}, opts);
    CHECK(result.cancelled);
    CHECK_FALSE(result.success());
    CHECK(result.elapsed_ms < 5000);
}
TEST_CASE("Executable preflight prevents starting a partially resolvable pipeline") {
    ProcessFixture f;
    auto marker = f.root / "must-not-exist.txt";
    CHECK_THROWS(pg::run_pipeline(
        {{{f.helper, "file", pg::utf8(marker), "bad"}, 1}, {{"missing-popgen-executable-123"}, 1}}, f.options()));
    CHECK_FALSE(pg::fs::exists(marker));
}
TEST_CASE("Completed jobs record CPU time and peak resident memory") {
    ProcessFixture f;
    auto result = pg::run_pipeline({{{f.helper, "allocate", "64"}, 1}}, f.options());
    REQUIRE(result.success());
    CHECK(result.max_rss_bytes >= 64ULL * 1024 * 1024);
    CHECK(result.record().at("max_rss_bytes") == result.max_rss_bytes);
    CHECK(result.cpu_user_ms + result.cpu_system_ms < result.elapsed_ms + 1000);
}
