#include "workflow.hpp"
#include <array>
#include <cstdlib>
#include <iostream>

int main() {
    try {
        auto args=pg::arguments();if(args.size()<2)return 2;auto mode=args[1];
        if(mode=="--version"){std::cout<<"PopGenA process-test-helper 1\n";return 0;}
        if(mode=="args") {std::cout<<pg::json(std::vector<std::string>(args.begin()+2,args.end())).dump();return 0;}
        if(mode=="env") {std::cout<<pg::json{{"omp",std::getenv("OMP_NUM_THREADS")},{"blas",std::getenv("OPENBLAS_NUM_THREADS")},{"mkl",std::getenv("MKL_NUM_THREADS")}}.dump();return 0;}
        if(mode=="copy") {
            std::array<char,8192> bytes{};DWORD n=0,written=0;
            while(ReadFile(GetStdHandle(STD_INPUT_HANDLE),bytes.data(),bytes.size(),&n,nullptr)&&n)
                if(!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),bytes.data(),n,&written,nullptr)||written!=n)return 3;
            return 0;
        }
        if(mode=="emit") {
            std::string bytes(static_cast<size_t>(std::stoul(args.at(2))),'x');DWORD written=0;
            return WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),bytes.data(),static_cast<DWORD>(bytes.size()),&written,nullptr)&&written==bytes.size()?0:3;
        }
        if(mode=="fail") {std::cout<<"partial output";std::cout.flush();CloseHandle(GetStdHandle(STD_OUTPUT_HANDLE));Sleep(200);return 23;}
        if(mode=="sleep") {Sleep(static_cast<DWORD>(std::stoul(args.at(2))));return 0;}
        if(mode=="allocate") {
            auto memory=VirtualAlloc(nullptr,static_cast<SIZE_T>(std::stoull(args.at(2)))*1024*1024,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE);
            if(!memory)return 42;
            VirtualFree(memory,0,MEM_RELEASE);return 0;
        }
        if(mode=="timed-file") {Sleep(static_cast<DWORD>(std::stoul(args.at(2))));pg::write_text(pg::from_utf8(args.at(3)),"completed");return 0;}
        if(mode=="file") {pg::write_text(pg::from_utf8(args.at(2)),args.at(3));return 0;}
        if(mode=="spawn") {
            auto self=pg::executable_path();auto line=pg::quote_windows(self.wstring())+L" sleep 30000";
            STARTUPINFOW startup{};startup.cb=sizeof(startup);PROCESS_INFORMATION info{};
            if(!CreateProcessW(self.c_str(),line.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&info))return 4;
            CloseHandle(info.hThread);CloseHandle(info.hProcess);
            pg::write_text(pg::from_utf8(args.at(2)),std::to_string(info.dwProcessId));Sleep(30000);return 0;
        }
        return 2;
    } catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 5;}
}
