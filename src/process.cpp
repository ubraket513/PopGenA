#include "workflow.hpp"
#include <algorithm>
#include <array>
#include <chrono>
#include <cwchar>
#include <set>
#include <stdexcept>

namespace pg {
namespace {
std::atomic_bool cancelled{false};
BOOL WINAPI control_handler(DWORD event) {
    if(event==CTRL_C_EVENT || event==CTRL_BREAK_EVENT || event==CTRL_CLOSE_EVENT) {
        cancelled.store(true); return TRUE;
    }
    return FALSE;
}
[[noreturn]] void win_error(const std::string& action) {
    throw std::runtime_error(action+" (Windows error "+std::to_string(GetLastError())+")");
}
struct Attributes {
    std::vector<unsigned char> bytes;
    LPPROC_THREAD_ATTRIBUTE_LIST list=nullptr;
    explicit Attributes(const std::vector<HANDLE>& handles) {
        SIZE_T size=0;
        InitializeProcThreadAttributeList(nullptr,1,0,&size);
        bytes.resize(size);
        auto p=reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(bytes.data());
        if(!InitializeProcThreadAttributeList(p,1,0,&size))win_error("Initialize handle list");
        list=p;
        if(!UpdateProcThreadAttribute(list,0,PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
            const_cast<HANDLE*>(handles.data()),handles.size()*sizeof(HANDLE),nullptr,nullptr)) {
            DeleteProcThreadAttributeList(list);list=nullptr;win_error("Set inherited handles");
        }
    }
    ~Attributes(){if(list)DeleteProcThreadAttributeList(list);}
};
WinHandle open_stream(const fs::path& path,DWORD access,DWORD creation) {
    SECURITY_ATTRIBUTES sa{sizeof(sa),nullptr,TRUE};
    WinHandle h(CreateFileW(path.c_str(),access,FILE_SHARE_READ|FILE_SHARE_WRITE,&sa,creation,FILE_ATTRIBUTE_NORMAL,nullptr));
    if(!h)win_error("Open process stream "+utf8(path));
    return h;
}
struct CaseInsensitive {
    bool operator()(const std::wstring& a,const std::wstring& b) const {return _wcsicmp(a.c_str(),b.c_str())<0;}
};
std::vector<wchar_t> environment(int threads) {
    auto block=GetEnvironmentStringsW();if(!block)win_error("Read process environment");
    std::map<std::wstring,std::wstring,CaseInsensitive> vars;
    for(auto p=block;*p;p+=wcslen(p)+1) {
        std::wstring entry(p);auto split=entry.find(L'=',entry[0]==L'='?1:0);
        if(split!=std::wstring::npos)vars[entry.substr(0,split)]=entry.substr(split+1);
    }
    FreeEnvironmentStringsW(block);
    vars[L"OMP_NUM_THREADS"]=std::to_wstring(threads);
    vars[L"OPENBLAS_NUM_THREADS"]=L"1";vars[L"MKL_NUM_THREADS"]=L"1";
    vars[L"LC_ALL"]=L"C";
    std::vector<wchar_t> result;
    for(const auto& [key,value]:vars) {
        auto entry=key+L"="+value;result.insert(result.end(),entry.begin(),entry.end());result.push_back(0);
    }
    result.push_back(0);return result;
}
}
void install_cancellation_handler() {
    if(!SetConsoleCtrlHandler(control_handler,TRUE))win_error("Install cancellation handler");
}
bool cancellation_requested(){return cancelled.load();}
fs::path executable_path() {
    std::array<wchar_t,32768> buffer{};
    auto size=GetModuleFileNameW(nullptr,buffer.data(),static_cast<DWORD>(buffer.size()));
    if(!size||size==buffer.size())win_error("Locate executable");
    return fs::canonical(fs::path(buffer.data()));
}
fs::path resolve_executable(const std::string& name,const fs::path& base) {
    if(name.empty()||name.find('\0')!=std::string::npos)throw std::runtime_error("Empty or invalid executable name");
    auto candidate=from_utf8(name);
    if(candidate.has_parent_path())candidate=fs::absolute(candidate.is_absolute()?candidate:base/candidate);
    else {
        auto local=executable_path().parent_path().parent_path()/".deps"/"ucrt64"/"bin"/candidate;
        if(!local.has_extension())local+=L".exe";
        if(fs::is_regular_file(local))candidate=local;
        else {
            std::array<wchar_t,32768> path{};
            auto size=SearchPathW(nullptr,candidate.c_str(),L".exe",static_cast<DWORD>(path.size()),path.data(),nullptr);
            if(!size||size>=path.size())throw std::runtime_error("Executable not found: "+name);
            candidate=path.data();
        }
    }
    auto ext=candidate.extension().wstring();std::transform(ext.begin(),ext.end(),ext.begin(),::towlower);
    if(ext!=L".exe"||!fs::is_regular_file(candidate))throw std::runtime_error("Expected a native .exe: "+name);
    return fs::canonical(candidate);
}
std::wstring quote_windows(const std::wstring& argument) {
    if(argument.find(L'\0')!=std::wstring::npos)throw std::runtime_error("NUL in command argument");
    std::wstring result=L"\"";size_t slashes=0;
    for(auto c:argument) {
        if(c==L'\\'){++slashes;continue;}
        if(c==L'\"'){result.append(slashes*2+1,L'\\');result+=c;}
        else {result.append(slashes,L'\\');result+=c;}
        slashes=0;
    }
    result.append(slashes*2,L'\\');result+=L'\"';return result;
}
bool ProcessResult::success() const {
    return !timed_out&&!cancelled&&!exit_codes.empty()&&std::all_of(exit_codes.begin(),exit_codes.end(),[](auto code){return code==0;});
}
json ProcessResult::record() const {
    return {{"exit_codes",exit_codes},{"timed_out",timed_out},{"cancelled",cancelled},{"elapsed_ms",elapsed_ms}};
}
ProcessResult run_pipeline(const std::vector<Command>& commands,const ProcessOptions& o) {
    if(commands.empty()||commands.size()>16)throw std::runtime_error("Pipeline must contain 1..16 commands");
    if(cancellation_requested()||(o.cancel&&o.cancel->load()))return {{},false,true,0};
    std::vector<fs::path> executables;
    for(const auto& cmd:commands){if(cmd.argv.empty()||cmd.threads<1)throw std::runtime_error("Invalid command");executables.push_back(resolve_executable(cmd.argv.front(),o.cwd));}
    WinHandle job(CreateJobObjectW(nullptr,nullptr));if(!job)win_error("Create pipeline job");
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if(o.memory_mb){limits.BasicLimitInformation.LimitFlags|=JOB_OBJECT_LIMIT_JOB_MEMORY;limits.JobMemoryLimit=o.memory_mb*1024ULL*1024ULL;}
    if(!SetInformationJobObject(job.get(),JobObjectExtendedLimitInformation,&limits,sizeof(limits)))win_error("Set job limits");
    auto output=open_stream(o.stdout_file,GENERIC_WRITE,CREATE_ALWAYS);
    auto error=open_stream(o.stderr_file,GENERIC_WRITE,CREATE_ALWAYS);
    auto null_input=open_stream(fs::path(L"NUL"),GENERIC_READ,OPEN_EXISTING);
    std::vector<WinHandle> children;
    WinHandle previous;
    auto start=std::chrono::steady_clock::now();
    auto elapsed=[&](){return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-start).count());};
    try {
        for(size_t i=0;i<commands.size();++i) {
            if(cancellation_requested()||(o.cancel&&o.cancel->load()))throw std::runtime_error("Cancelled during process launch");
            WinHandle next_read,next_write;
            if(i+1<commands.size()) {
                SECURITY_ATTRIBUTES sa{sizeof(sa),nullptr,TRUE};HANDLE r=nullptr,w=nullptr;
                if(!CreatePipe(&r,&w,&sa,0))win_error("Create pipeline pipe");
                next_read.reset(r);next_write.reset(w);
            }
            STARTUPINFOEXW startup{};startup.StartupInfo.cb=sizeof(startup);
            startup.StartupInfo.dwFlags=STARTF_USESTDHANDLES|STARTF_USESHOWWINDOW;startup.StartupInfo.wShowWindow=SW_HIDE;
            startup.StartupInfo.hStdInput=previous?previous.get():null_input.get();
            startup.StartupInfo.hStdOutput=next_write?next_write.get():output.get();
            startup.StartupInfo.hStdError=error.get();
            std::vector<HANDLE> handles{startup.StartupInfo.hStdInput,startup.StartupInfo.hStdOutput,startup.StartupInfo.hStdError};
            Attributes attributes(handles);startup.lpAttributeList=attributes.list;
            std::wstring line=quote_windows(executables[i].wstring());
            for(size_t j=1;j<commands[i].argv.size();++j)line+=L" "+quote_windows(from_utf8(commands[i].argv[j]).wstring());
            if(line.size()>32760)throw std::runtime_error("Windows command line too long");
            auto env=environment(commands[i].threads);PROCESS_INFORMATION info{};
            if(!CreateProcessW(executables[i].c_str(),line.data(),nullptr,nullptr,TRUE,
                CREATE_SUSPENDED|CREATE_NO_WINDOW|CREATE_UNICODE_ENVIRONMENT|EXTENDED_STARTUPINFO_PRESENT,
                env.data(),o.cwd.c_str(),&startup.StartupInfo,&info))win_error("Launch "+utf8(executables[i]));
            WinHandle process(info.hProcess),thread(info.hThread);
            if(!AssignProcessToJobObject(job.get(),process.get())) {
                TerminateProcess(process.get(),125);WaitForSingleObject(process.get(),5000);win_error("Assign child to pipeline job");
            }
            children.push_back(std::move(process));
            if(ResumeThread(thread.get())==static_cast<DWORD>(-1))win_error("Resume child");
            previous=std::move(next_read);
        }
        previous.reset();output.reset();error.reset();null_input.reset();
        ProcessResult result;result.exit_codes.resize(children.size(),STILL_ACTIVE);
        bool terminated=false;
        for(;;) {
            bool finished=true,failed=false;
            for(size_t i=0;i<children.size();++i) {
                auto wait=WaitForSingleObject(children[i].get(),0);
                if(wait==WAIT_FAILED)win_error("Wait for process");
                if(wait==WAIT_OBJECT_0) {
                    DWORD code=0;if(!GetExitCodeProcess(children[i].get(),&code))win_error("Read process exit status");result.exit_codes[i]=code;
                    if(code)failed=true;
                } else finished=false;
            }
            result.cancelled=cancellation_requested()||(o.cancel&&o.cancel->load());
            result.timed_out=o.timeout_ms&&elapsed()>=o.timeout_ms&&!finished;
            if(finished)break;
            if(failed||result.cancelled||result.timed_out) {
                if(!TerminateJobObject(job.get(),result.cancelled?130:result.timed_out?124:125))win_error("Terminate pipeline job");
                terminated=true;break;
            }
            Sleep(20);
        }
        if(terminated)for(size_t i=0;i<children.size();++i) {
            if(WaitForSingleObject(children[i].get(),5000)!=WAIT_OBJECT_0)throw std::runtime_error("Timed out waiting for terminated child");
            DWORD code=0;if(!GetExitCodeProcess(children[i].get(),&code))win_error("Read terminated child status");result.exit_codes[i]=code;
        }
        // Also terminate descendants that outlived their direct parent before publishing outputs.
        if(!TerminateJobObject(job.get(),125))win_error("Close pipeline descendants");
        for(int tries=0;tries<250;++tries) {
            JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting{};
            if(!QueryInformationJobObject(job.get(),JobObjectBasicAccountingInformation,&accounting,sizeof(accounting),nullptr))win_error("Query job cleanup");
            if(!accounting.ActiveProcesses){result.elapsed_ms=elapsed();return result;}
            Sleep(20);
        }
        throw std::runtime_error("Pipeline descendants did not exit within cleanup timeout");
    } catch(...) {
        TerminateJobObject(job.get(),125);
        for(auto& child:children)WaitForSingleObject(child.get(),5000);
        throw;
    }
}
WinHandle exclusive_lock(const fs::path& path) {
    WinHandle h(CreateFileW(path.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_HIDDEN|FILE_FLAG_DELETE_ON_CLOSE,nullptr));
    if(!h)throw std::runtime_error("Workflow is locked or not writable: "+utf8(path));
    return h;
}
void atomic_text(const fs::path& path,const std::string& content) {
    if(fs::is_regular_file(path)&&read_text(path)==content)return;
    auto temp=path;temp+=from_utf8(".tmp-"+unique_id());
    try {
        write_text(temp,content);
        if(!MoveFileExW(temp.c_str(),path.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH))win_error("Publish metadata "+utf8(path));
    } catch(...) {std::error_code ec;fs::remove(temp,ec);throw;}
}
json file_identity(const fs::path& path,bool full) {
    if(!fs::is_regular_file(path))throw std::runtime_error("Required file missing: "+utf8(path));
    auto p=fs::canonical(path);auto size=fs::file_size(p);auto time=fs::last_write_time(p);
    json id={{"path",utf8(p)},{"size",size},{"mtime",time.time_since_epoch().count()}};
    if(full||size<=16*1024*1024)id["sha256"]=sha256(p);
    if(size!=fs::file_size(p)||time!=fs::last_write_time(p))throw std::runtime_error("File changed while identifying it: "+utf8(p));
    return id;
}
std::string ninja_path(const std::string& path) {
    std::string out;
    for(char c:path) {
        if(c=='\n'||c=='\r'||c=='\0'||c=='|')throw std::runtime_error("Unsupported character in Ninja path");
        if(c=='$'||c==' '||c==':')out+='$';
        out+=c;
    }
    return out;
}
}
