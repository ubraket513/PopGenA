#include "popgen.hpp"
#include <windows.h>
#include <shellapi.h>
#include <bcrypt.h>
#include <htslib/hts.h>
#include <array>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <memory>
namespace pg {
std::string utf8(const fs::path& path) {
    auto bytes = path.u8string();
    return {reinterpret_cast<const char*>(bytes.data()), bytes.size()};
}
std::vector<std::string> arguments() {
    int count=0;
    auto raw=CommandLineToArgvW(GetCommandLineW(), &count);
    if (!raw) throw std::runtime_error("Cannot decode Windows command line");
    std::vector<std::string> result;
    for (int i=0;i<count;++i) result.push_back(utf8(fs::path(raw[i])));
    LocalFree(raw);
    return result;
}
std::string read_text(const fs::path& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("Cannot read " + utf8(path));
    std::ostringstream data; data << in.rdbuf();
    if (in.bad()) throw std::runtime_error("Read failed: " + utf8(path));
    return data.str();
}
void write_text(const fs::path& path, const std::string& value) {
    std::ofstream out(path, std::ios::binary);
    out.exceptions(std::ios::failbit | std::ios::badbit);
    out << value; out.close();
}
std::string unique_id() {
    std::array<unsigned char,16> bytes{};
    if (BCryptGenRandom(nullptr,bytes.data(),static_cast<ULONG>(bytes.size()),BCRYPT_USE_SYSTEM_PREFERRED_RNG)<0)
        throw std::runtime_error("Cannot generate temporary name");
    std::ostringstream out;
    for(auto b:bytes) out << std::hex << std::setw(2) << std::setfill('0') << int(b);
    return out.str();
}
std::string sha256(const fs::path& path) {
    BCRYPT_ALG_HANDLE algorithm=nullptr; BCRYPT_HASH_HANDLE hash=nullptr;
    struct Cleanup { BCRYPT_ALG_HANDLE& a; BCRYPT_HASH_HANDLE& h;
        ~Cleanup(){if(h)BCryptDestroyHash(h);if(a)BCryptCloseAlgorithmProvider(a,0);} } cleanup{algorithm,hash};
    if(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)<0 ||
       BCryptCreateHash(algorithm,&hash,nullptr,0,nullptr,0,0)<0)
        throw std::runtime_error("Cannot initialize SHA256");
    std::ifstream in(path,std::ios::binary);
    if(!in) throw std::runtime_error("Cannot hash " + utf8(path));
    std::array<char,65536> buffer{};
    while(in) {
        in.read(buffer.data(),buffer.size());
        if(BCryptHashData(hash,reinterpret_cast<PUCHAR>(buffer.data()),static_cast<ULONG>(in.gcount()),0)<0)
            throw std::runtime_error("SHA256 update failed");
    }
    if(in.bad()) throw std::runtime_error("SHA256 read failed");
    std::array<unsigned char,32> digest{};
    if(BCryptFinishHash(hash,digest.data(),digest.size(),0)<0) throw std::runtime_error("SHA256 finish failed");
    std::ostringstream out;
    for(auto b:digest) out << std::hex << std::setw(2) << std::setfill('0') << int(b);
    return out.str();
}
json doctor() {
    json result={{"application","PopGenA"},{"version",version},{"platform","windows-x86_64"},{"htslib",hts_version()}};
    std::array<wchar_t,32768> executable{};
    auto length=GetModuleFileNameW(nullptr,executable.data(),static_cast<DWORD>(executable.size()));
    if(!length||length==executable.size()) throw std::runtime_error("Cannot locate application directory");
    auto local=fs::path(executable.data()).parent_path().parent_path()/".deps"/"ucrt64"/"bin";
    result["optional_tools"]=json::object();
    for(const auto* name:{L"bcftools.exe",L"samtools.exe",L"plink2.exe",L"fastp.exe",L"bwa.exe",L"Rscript.exe"}) {
        auto candidate=local/name;
        if(std::wstring(name)==L"plink2.exe")candidate=local.parent_path().parent_path()/"plink2/plink2.exe";
        if(fs::is_regular_file(candidate)) {
            result["optional_tools"][utf8(fs::path(name))]=utf8(candidate);
            continue;
        }
        std::array<wchar_t,32768> path{};
        auto n=SearchPathW(nullptr,name,nullptr,static_cast<DWORD>(path.size()),path.data(),nullptr);
        result["optional_tools"][utf8(fs::path(name))]=(n && n<path.size()) ? json(utf8(fs::path(path.data()))) : json(nullptr);
    }
    return result;
}
}
