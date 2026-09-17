// Child process used by the run_pipeline unit tests.
#include "workflow.hpp"
#include <unistd.h>
#include <array>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <thread>
#include <vector>

namespace {
void sleep_ms(unsigned long ms) {
    std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}
bool write_all(int fd, const char* data, size_t size) {
    while (size) {
        auto n = ::write(fd, data, size);
        if (n <= 0) return false;
        data += n;
        size -= static_cast<size_t>(n);
    }
    return true;
}
}

int main() {
    try {
        auto args = pg::arguments();
        if (args.size() < 2) return 2;
        const auto& mode = args[1];
        if (mode == "--version") {
            std::cout << "PopGenA process-test-helper 1\n";
            return 0;
        }
        if (mode == "args") {
            std::cout << pg::json(std::vector<std::string>(args.begin() + 2, args.end())).dump();
            return 0;
        }
        if (mode == "env") {
            std::cout << pg::json{{"omp", std::getenv("OMP_NUM_THREADS")},
                                  {"blas", std::getenv("OPENBLAS_NUM_THREADS")},
                                  {"mkl", std::getenv("MKL_NUM_THREADS")},
                                  {"locale", std::getenv("LC_ALL")}}
                             .dump();
            return 0;
        }
        if (mode == "copy") {
            std::array<char, 8192> bytes{};
            for (ssize_t n; (n = ::read(0, bytes.data(), bytes.size())) > 0;)
                if (!write_all(1, bytes.data(), static_cast<size_t>(n))) return 3;
            return 0;
        }
        if (mode == "emit") {
            std::string bytes(std::stoul(args.at(2)), 'x');
            return write_all(1, bytes.data(), bytes.size()) ? 0 : 3;
        }
        if (mode == "fail") {
            std::cout << "partial output" << std::flush;
            ::close(1);
            sleep_ms(200);
            return 23;
        }
        if (mode == "sleep") {
            sleep_ms(std::stoul(args.at(2)));
            return 0;
        }
        if (mode == "allocate") {
            // Touch every page so the memory counts towards resident set size.
            std::vector<char> memory(std::stoull(args.at(2)) * 1024 * 1024);
            for (size_t i = 0; i < memory.size(); i += 4096) memory[i] = 1;
            return 0;
        }
        if (mode == "file") {
            pg::write_text(pg::from_utf8(args.at(2)), args.at(3));
            return 0;
        }
        if (mode == "timed-file") {
            sleep_ms(std::stoul(args.at(2)));
            pg::write_text(pg::from_utf8(args.at(3)), "completed");
            return 0;
        }
        if (mode == "spawn") {
            // Leave a grandchild behind that must be killed with the process group.
            pid_t pid = ::fork();
            if (pid < 0) return 4;
            if (pid == 0) {
                sleep_ms(30000);
                ::_exit(0);
            }
            pg::write_text(pg::from_utf8(args.at(2)), std::to_string(pid));
            sleep_ms(30000);
            return 0;
        }
        return 2;
    } catch (const std::exception& e) {
        std::cerr << e.what() << '\n';
        return 5;
    }
}
