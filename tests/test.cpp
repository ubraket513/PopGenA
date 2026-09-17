#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <doctest.h>
#include "popgen.hpp"
#include "workflow.hpp"
#include <fstream>
#include <thread>
TEST_CASE("Autosome mapping is explicit and rejects ambiguous names") {
    for(int i=1;i<=22;++i){CHECK(pg::autosome(std::to_string(i)));CHECK(pg::autosome("chr"+std::to_string(i)));}
    for(const auto* s:{"0","23","X","chrX","chr01","01","1_random","CHR1",""})CHECK_FALSE(pg::autosome(s));
}
TEST_CASE("Missing denominators and TSV trailing fields are preserved") {
    CHECK(pg::ratio(1,0)=="NA");CHECK(pg::ratio(1,4)=="0.25");
    CHECK(pg::split_tsv("a\tb\t")==std::vector<std::string>{"a","b",""});
}
TEST_CASE("SHA256 matches a published known digest") {
    auto p=pg::fs::temp_directory_path()/pg::unique_id();pg::write_text(p,"abc");
    CHECK(pg::sha256(p)=="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");pg::fs::remove(p);
}
TEST_CASE("Counts preserve independent called and excluded categories") {
    pg::Counts a{2,1,3,4,5,6},b{3,2,4,5,6,7};a.add(b);
    CHECK(a.called==5);CHECK(a.het==3);CHECK(a.alt==7);CHECK(a.missing==9);CHECK(a.filtered==11);CHECK(a.unsupported==13);
}

namespace {
struct ProcessFixture {
    pg::fs::path root=pg::executable_path().parent_path()/pg::from_utf8("process-test-"+pg::unique_id());
    std::string helper=pg::utf8(pg::executable_path().parent_path()/"process-helper.exe");
    ProcessFixture(){pg::fs::create_directory(root);}
    pg::ProcessOptions options(uint64_t timeout=5000) const {return {root,root/"stdout.log",root/"stderr.log",timeout,256,nullptr};}
};
}
TEST_CASE("Native argument passing preserves Unicode quotes empty strings and shell metacharacters") {
    ProcessFixture f;
    std::vector<std::string> values={"","a b","trailing\\","a\\\"b","$&|<>%^!","\"quoted\"",pg::utf8(pg::fs::path(L"샘플"))};
    pg::Command command{{f.helper,"args"},3};command.argv.insert(command.argv.end(),values.begin(),values.end());
    auto result=pg::run_pipeline({command},f.options());REQUIRE(result.success());
    CHECK(pg::json::parse(pg::read_text(f.root/"stdout.log"))==values);
    result=pg::run_pipeline({{{f.helper,"env"},3}},f.options());REQUIRE(result.success());
    auto env=pg::json::parse(pg::read_text(f.root/"stdout.log"));CHECK(env["omp"]=="3");CHECK(env["blas"]=="1");CHECK(env["mkl"]=="1");
}
TEST_CASE("Binary pipeline drains buffers and upstream failures cannot be hidden") {
    ProcessFixture f;
    auto result=pg::run_pipeline({{{f.helper,"emit","262144"},1},{{f.helper,"copy"},1}},f.options());
    REQUIRE(result.success());CHECK(pg::fs::file_size(f.root/"stdout.log")==262144);
    result=pg::run_pipeline({{{f.helper,"fail"},1},{{f.helper,"copy"},1}},f.options());
    CHECK_FALSE(result.success());CHECK(result.exit_codes[0]==23);CHECK(result.exit_codes[1]==0);
    result=pg::run_pipeline({{{f.helper,"fail"},1},{{f.helper,"sleep","30000"},1}},f.options());
    CHECK_FALSE(result.success());CHECK(result.elapsed_ms<5000);
}
TEST_CASE("Timeout and cancellation clean up process trees") {
    ProcessFixture f;auto pidfile=f.root/"descendant.pid";
    auto result=pg::run_pipeline({{{f.helper,"spawn",pg::utf8(pidfile)},1}},f.options(500));
    CHECK(result.timed_out);CHECK_FALSE(result.success());REQUIRE(pg::fs::exists(pidfile));
    DWORD pid=static_cast<DWORD>(std::stoul(pg::read_text(pidfile)));
    pg::WinHandle descendant(OpenProcess(SYNCHRONIZE,FALSE,pid));
    if(descendant)CHECK(WaitForSingleObject(descendant.get(),0)==WAIT_OBJECT_0);
    std::atomic_bool cancel{false};auto opts=f.options();opts.cancel=&cancel;
    std::jthread interrupt([&]{std::this_thread::sleep_for(std::chrono::milliseconds(150));cancel.store(true);});
    result=pg::run_pipeline({{{f.helper,"sleep","30000"},1}},opts);
    CHECK(result.cancelled);CHECK_FALSE(result.success());CHECK(result.elapsed_ms<5000);
}
TEST_CASE("Executable preflight prevents starting a partially resolvable pipeline") {
    ProcessFixture f;auto marker=f.root/"must-not-exist.txt";
    CHECK_THROWS(pg::run_pipeline({{{f.helper,"file",pg::utf8(marker),"bad"},1},{{"missing-popgen-executable-123.exe"},1}},f.options()));
    CHECK_FALSE(pg::fs::exists(marker));
}
TEST_CASE("Job committed-memory cap rejects allocations beyond the task reservation") {
    ProcessFixture f;auto options=f.options();options.memory_mb=64;
    auto result=pg::run_pipeline({{{f.helper,"allocate","256"},1}},options);
    REQUIRE_FALSE(result.success());CHECK(result.exit_codes[0]==42);
}
TEST_CASE("Completed jobs retain peak committed memory and IO accounting") {
    ProcessFixture f;
    auto result=pg::run_pipeline({{{f.helper,"allocate","32"},1}},f.options());
    REQUIRE(result.success());CHECK(result.peak_job_committed_bytes>=32ULL*1024*1024);
    CHECK(result.record().at("peak_job_committed_bytes")==result.peak_job_committed_bytes);
    result=pg::run_pipeline({{{f.helper,"emit","262144"},1}},f.options());
    REQUIRE(result.success());CHECK(result.io_write_bytes>=262144);
}
