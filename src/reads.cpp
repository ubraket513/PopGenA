#include "reads.hpp"
#include "workflow.hpp"
#include <htslib/kseq.h>
#include <htslib/faidx.h>
#include <htslib/sam.h>
#include <zlib.h>
#include <algorithm>
#include <fstream>
#include <map>
#include <memory>
#include <regex>
#include <set>
#include <sstream>
#include <stdexcept>
KSEQ_INIT(gzFile,gzread)
namespace pg {
namespace {
void require(bool ok,const std::string& m){if(!ok)throw std::runtime_error(m);}
void keys(const json& j,std::initializer_list<const char*> names){require(j.is_object(),"Expected reads configuration object");std::set<std::string> allowed(names.begin(),names.end());for(const auto& [k,v]:j.items()){(void)v;require(allowed.contains(k),"Unknown reads configuration key: "+k);}}
std::string text(const json& j,const char* key){require(j.contains(key)&&j[key].is_string(),std::string(key)+" must be a string");auto s=j[key].get<std::string>();require(!s.empty()&&s.find_first_of("\r\n\t")==std::string::npos&&s.find('\0')==std::string::npos,"Invalid "+std::string(key));return s;}
uint64_t number(const json& j,const char* key,uint64_t fallback,uint64_t low,uint64_t high){auto v=fallback;if(j.contains(key)){require(j[key].is_number_integer()&&j[key].get<int64_t>()>=0,std::string(key)+" must be a nonnegative integer");v=j[key].get<uint64_t>();}require(v>=low&&v<=high,std::string(key)+" outside supported range");return v;}
bool flag(const json& j,const char* key,bool fallback){if(!j.contains(key))return fallback;require(j[key].is_boolean(),std::string(key)+" must be boolean");return j[key].get<bool>();}
void identifier(const std::string& s){require(std::regex_match(s,std::regex("[A-Za-z][A-Za-z0-9_.-]{0,63}")),"Run/sample/library IDs must start with a letter and contain only letters, digits, dot, underscore or hyphen");}
fs::path source(const json& c,const char* key,const fs::path& base){auto p=from_utf8(text(c,key));return fs::canonical(p.is_absolute()?p:base/p);}
struct SequenceReader {
    gzFile file=nullptr;kseq_t* seq=nullptr;
    explicit SequenceReader(const fs::path& p){file=gzopen(utf8(p).c_str(),"rb");require(file!=nullptr,"Cannot open sequence input: "+utf8(p));seq=kseq_init(file);if(!seq){gzclose(file);file=nullptr;throw std::bad_alloc();}}
    ~SequenceReader(){if(seq)kseq_destroy(seq);if(file)gzclose(file);}
    int next(){auto n=kseq_read(seq);int error=0;gzerror(file,&error);require(error==Z_OK||error==Z_STREAM_END,"Compressed input is corrupt or truncated");require(n>=-1,"Malformed FASTQ record");return n;}
};
struct FastqReader {
    gzFile file=nullptr;std::string name,sequence;
    explicit FastqReader(const fs::path& p){file=gzopen(utf8(p).c_str(),"rb");require(file!=nullptr,"Cannot open FASTQ: "+utf8(p));}
    ~FastqReader(){if(file)gzclose(file);}
    bool line(std::string& value){value.clear();char buffer[4096];bool any=false;
        while(gzgets(file,buffer,sizeof(buffer))){any=true;value+=buffer;require(value.size()<=1048576,"FASTQ line exceeds 1 MiB supported limit");if(value.back()=='\n')break;}
        int error=0;gzerror(file,&error);require(error==Z_OK||error==Z_STREAM_END,"Compressed FASTQ is corrupt or truncated");if(!any)return false;
        if(value.back()=='\n')value.pop_back();
        if(!value.empty()&&value.back()=='\r')value.pop_back();
        return true;}
    bool next(int mate){std::string header,plus,quality;if(!line(header))return false;require(!header.empty()&&header[0]=='@',"FASTQ record must start with @");
        require(line(sequence)&&line(plus)&&line(quality),"Truncated four-line FASTQ record");require(!plus.empty()&&plus[0]=='+',"FASTQ separator must start with +");require(!sequence.empty()&&sequence.size()==quality.size(),"FASTQ sequence and quality lengths differ");
        auto sep=header.find_first_of(" \t");name=header.substr(1,sep==std::string::npos?std::string::npos:sep-1);require(!name.empty(),"Empty FASTQ read name");
        if(name.ends_with("/1")||name.ends_with("/2")){require(name.back()==char('0'+mate),"FASTQ mate suffix is reversed");name.resize(name.size()-2);}
        if(sep!=std::string::npos){auto comment=header.find_first_not_of(" \t",sep);if(comment!=std::string::npos&&comment+1<header.size()&&header[comment+1]==':'&&(header[comment]=='1'||header[comment]=='2'))require(header[comment]==char('0'+mate),"FASTQ CASAVA mate tag is reversed");}
        for(size_t i=0;i<sequence.size();++i){require(std::string("ACGTNacgtn").find(sequence[i])!=std::string::npos,"Unsupported FASTQ base");auto q=static_cast<unsigned char>(quality[i]);require(q>=33&&q<=126,"FASTQ quality is not Phred+33 ASCII");}return true;}
};
std::map<std::string,std::string> metadata(const fs::path& file,const std::set<std::string>& expected){
    std::map<std::string,std::string> result;if(file.empty()){for(const auto& id:expected)result[id]="ALL";return result;}
    std::ifstream in(file);require(bool(in),"Cannot read raw sample metadata");std::string line;require(bool(std::getline(in,line)),"Empty sample metadata");if(line.starts_with("\xEF\xBB\xBF"))line.erase(0,3);if(!line.empty()&&line.back()=='\r')line.pop_back();
    auto h=split_tsv(line);auto si=std::find(h.begin(),h.end(),"sample"),pi=std::find(h.begin(),h.end(),"population");require(si!=h.end()&&pi!=h.end()&&std::set<std::string>(h.begin(),h.end()).size()==h.size(),"Metadata requires unique sample/population columns");
    while(std::getline(in,line)){if(!line.empty()&&line.back()=='\r')line.pop_back();auto row=split_tsv(line);require(row.size()==h.size(),"Malformed sample metadata");auto id=row[si-h.begin()],pop=row[pi-h.begin()];require(expected.contains(id)&&!pop.empty()&&result.emplace(id,pop).second,"Unknown/duplicate sample or empty population");}
    require(!in.bad()&&result.size()==expected.size(),"Metadata must match unique run samples exactly");return result;
}
}

json check_fastq_pair(const fs::path& first,const fs::path& second){
    require(!fs::equivalent(first,second),"Read mates must be different files");FastqReader a(first),b(second);uint64_t pairs=0,bases=0,min_length=UINT64_MAX,max_length=0;
    for(;;){bool n=a.next(1),m=b.next(2);require(n==m,"FASTQ mates have different record counts");if(!n)break;require(a.name==b.name,"FASTQ mate names do not match");++pairs;bases+=a.sequence.size()+b.sequence.size();min_length=std::min<uint64_t>(min_length,std::min(a.sequence.size(),b.sequence.size()));max_length=std::max<uint64_t>(max_length,std::max(a.sequence.size(),b.sequence.size()));}
    require(pairs>0,"FASTQ pair contains no reads");return {{"pairs",pairs},{"bases",bases},{"min_length",min_length},{"max_length",max_length},{"quality_encoding","Phred+33"}};
}

json normalize_fastp_report(const fs::path& report,const fs::path& before,const json& after,const fs::path& output){
    require(fs::file_size(report)<=67108864,"fastp report exceeds supported size");auto contents=read_text(report);json parsed;bool repaired=false;
    try{parsed=json::parse(contents);}catch(const json::parse_error&){
        // fastp 1.3.3 writes its final command field without JSON-escaping Windows paths.
        auto pos=contents.rfind("\"command\":");require(pos!=std::string::npos,"Invalid fastp JSON report");auto suffix=contents.substr(pos);auto end=suffix.find_last_not_of(" \r\n\t");require(end!=std::string::npos&&suffix[end]=='}',"Unexpected fastp report suffix");
        auto last=suffix.find_last_not_of(" \r\n\t",end-1);require(last!=std::string::npos&&suffix[last]=='\"',"Malformed fastp command field");contents.replace(pos,contents.size()-pos,"\"command\": null\n}\n");parsed=json::parse(contents);repaired=true;
    }
    auto original=json::parse(read_text(before));require(parsed.at("summary").at("before_filtering").at("total_reads").get<uint64_t>()==2*original.at("pairs").get<uint64_t>(),"fastp input counts differ from validated FASTQ");
    require(parsed.at("summary").at("after_filtering").at("total_reads").get<uint64_t>()==2*after.at("pairs").get<uint64_t>(),"fastp output counts differ from validated FASTQ");require(!fs::exists(output),"Normalized fastp report already exists");
    parsed["popgen_report_adapter"]={{"unescaped_command_removed",repaired},{"exact_command_source","workflow task attempt.json commands argv"},{"paired_counts_validated",true}};write_text(output,parsed.dump(2)+"\n");return parsed["popgen_report_adapter"];
}

json prepare_reference(const fs::path& input,const fs::path& out,const std::string& expected,uint64_t max_bases){
    require(std::regex_match(expected,std::regex("[0-9a-f]{64}")),"Reference SHA256 must be lowercase hexadecimal");require(sha256(input)==expected,"Reference SHA256 does not match the explicit identity");
    std::ifstream first(input,std::ios::binary);require(first.get()=='>',"Reference must be an uncompressed FASTA");first.close();
    SequenceReader reader(input);std::set<std::string> names,autosomes_seen;uint64_t total=0;std::string regions;json contigs=json::object();
    while(reader.next()>=0){auto* s=reader.seq;std::string name(s->name.s,s->name.l);require(!name.empty()&&names.insert(name).second&&s->qual.l==0,"Invalid/duplicate FASTA contig or FASTQ reference");require(s->seq.l>0&&s->seq.l<=max_bases-total,"Reference exceeds configured base budget");total+=s->seq.l;contigs[name]=s->seq.l;
        if(autosome(name)){auto canonical=name.starts_with("chr")?name.substr(3):name;require(autosomes_seen.insert(canonical).second,"Reference contains both numeric and chr-prefixed versions of an autosome");regions+=name+"\t0\t"+std::to_string(s->seq.l)+"\n";}}
    require(!regions.empty(),"Reference has no recognized human autosomes");fs::create_directories(out);auto copy=out/"reference.fa";require(!fs::exists(copy),"Reference output already exists");fs::copy_file(input,copy);
    require(sha256(copy)==expected,"Reference changed while copying");require(fai_build3(utf8(copy).c_str(),nullptr,nullptr)==0,"Cannot index reference FASTA");write_text(out/"autosomes.bed",regions);write_text(out/"ploidy.txt","* * * * 2\n");
    return {{"sha256",expected},{"bases",total},{"contigs",contigs},{"autosomes",autosomes_seen.size()}};
}

json check_alignments(const std::vector<std::string>& files,const std::vector<std::string>& samples,const std::vector<std::string>& libraries,const fs::path& reference,const fs::path& sample_file,const fs::path& out){
    require(!files.empty()&&files.size()==samples.size()&&files.size()==libraries.size(),"BAMs, samples and libraries must have matching counts");
    using File=std::unique_ptr<samFile,decltype(&hts_close)>;using Header=std::unique_ptr<sam_hdr_t,decltype(&sam_hdr_destroy)>;using Record=std::unique_ptr<bam1_t,decltype(&bam_destroy1)>;
    using Fai=std::unique_ptr<faidx_t,decltype(&fai_destroy)>;Fai fai(fai_load(utf8(reference).c_str()),&fai_destroy);require(bool(fai),"Cannot read prepared reference index");
    json reports=json::array();std::string list;std::set<std::string> cohort(samples.begin(),samples.end()),global_rg;auto populations=metadata(sample_file,cohort);
    for(size_t i=0;i<files.size();++i){File input(sam_open(files[i].c_str(),"rb"),&hts_close);require(bool(input),"Cannot read aligned BAM");Header header(sam_hdr_read(input.get()),&sam_hdr_destroy);require(bool(header),"Invalid alignment header");
        require(sam_hdr_nref(header.get())==faidx_nseq(fai.get()),"Alignment/reference dictionaries differ");
        for(int tid=0;tid<sam_hdr_nref(header.get());++tid)require(faidx_seq_len64(fai.get(),sam_hdr_tid2name(header.get(),tid))==sam_hdr_tid2len(header.get(),tid),"Alignment/reference contig length differs");
        std::set<std::string> rgs;std::istringstream lines(sam_hdr_str(header.get()));std::string line;
        while(std::getline(lines,line)){if(!line.starts_with("@RG\t"))continue;auto fields=split_tsv(line);std::map<std::string,std::string> tags;for(size_t j=1;j<fields.size();++j)if(fields[j].size()>=3&&fields[j][2]==':')require(tags.emplace(fields[j].substr(0,2),fields[j].substr(3)).second,"Duplicate RG tag");
            require(tags.contains("ID")&&tags["SM"]==samples[i]&&tags["LB"]==libraries[i]&&tags["PL"]=="ILLUMINA","Read group sample/library/platform differs from configuration");require(rgs.insert(tags["ID"]).second&&global_rg.insert(tags["ID"]).second,"Duplicate read-group identity");}
        require(!rgs.empty(),"BAM has no read groups");std::unique_ptr<hts_idx_t,decltype(&hts_idx_destroy)> index(sam_index_load(input.get(),files[i].c_str()),&hts_idx_destroy);require(bool(index),"BAM CSI index missing/invalid");
        Record record(bam_init1(),&bam_destroy1);require(bool(record),"Cannot allocate BAM record");uint64_t records=0,mapped=0,duplicates=0,usable=0;int status,previous_tid=-1;hts_pos_t previous_pos=-1;bool unmapped_tail=false;
        while((status=sam_read1(input.get(),header.get(),record.get()))>=0){++records;auto* rg=bam_aux_get(record.get(),"RG");auto* id=rg?bam_aux2Z(rg):nullptr;require(id&&rgs.contains(id),"Record read group is absent/unknown");auto flags=record->core.flag;
            if(record->core.tid<0)unmapped_tail=true;else{require(!unmapped_tail&&(record->core.tid>previous_tid||(record->core.tid==previous_tid&&record->core.pos>=previous_pos)),"BAM is not coordinate sorted");previous_tid=record->core.tid;previous_pos=record->core.pos;}
            if(!(flags&BAM_FUNMAP))++mapped;
            if(flags&BAM_FDUP)++duplicates;
            if((flags&BAM_FPROPER_PAIR)&&!(flags&(BAM_FUNMAP|BAM_FSECONDARY|BAM_FSUPPLEMENTARY|BAM_FQCFAIL|BAM_FDUP)))++usable;}
        require(status==-1&&hts_check_EOF(input.get())==1,"Truncated or malformed aligned BAM");require(usable>0,"No usable primary proper-pair alignments in a library");list+=files[i]+"\n";reports.push_back({{"sample",samples[i]},{"library",libraries[i]},{"records",records},{"mapped",mapped},{"duplicates",duplicates},{"usable_primary_records",usable}});
    }
    fs::create_directories(out);require(!fs::exists(out/"bams.list")&&!fs::exists(out/"samples.tsv"),"BAM manifest already exists");write_text(out/"bams.list",list);std::string table="sample\tpopulation\n";for(const auto& [sample,pop]:populations)table+=sample+"\t"+pop+"\n";write_text(out/"samples.tsv",table);
    return {{"samples",cohort.size()},{"libraries",reports},{"duplicate_policy","mark per sample/library after merging runs; exclude duplicates during joint calling"}};
}

json expand_reads(const json& c,const fs::path& base){
    keys(c,{"schema_version","workflow_type","work_dir","assembly","reference","reference_sha256","samples","runs","resources","limits","processing","qc","tools"});
    require(number(c,"schema_version",0,1,1)==1&&text(c,"workflow_type")=="reads","Invalid reads schema/type");auto assembly=text(c,"assembly");auto ref=source(c,"reference",base);auto hash=text(c,"reference_sha256");require(std::regex_match(hash,std::regex("[0-9a-f]{64}")),"Explicit reference_sha256 required");
    auto limits=c.at("limits");keys(limits,{"input_bytes","reference_bases","scratch_bytes"});uint64_t max_input=number(limits,"input_bytes",0,1,500000000000ULL),max_ref=number(limits,"reference_bases",0,1,3900000000ULL),scratch=number(limits,"scratch_bytes",0,67108864,500000000000ULL);
    auto p=c.value("processing",json::object());keys(p,{"threads","memory_mb","timeout_seconds","min_length","qualified_quality","unqualified_percent","trim_adapters","max_fragment","min_mapping_quality","min_base_quality","max_depth"});
    int threads=int(number(p,"threads",2,1,4)),memory=int(number(p,"memory_mb",6144,1024,10240)),timeout=int(number(p,"timeout_seconds",3600,1,604800));
    int length=int(number(p,"min_length",35,15,10000)),quality=int(number(p,"qualified_quality",20,0,40)),unqualified=int(number(p,"unqualified_percent",40,0,100)),fragment=int(number(p,"max_fragment",1000,1,100000));
    int mapq=int(number(p,"min_mapping_quality",20,0,60)),baseq=int(number(p,"min_base_quality",20,0,60)),depth=int(number(p,"max_depth",250,1,1000000));bool adapters=flag(p,"trim_adapters",true);
    auto q=c.value("qc",json::object());keys(q,{"min_dp","min_gq"});int dp=int(number(q,"min_dp",5,1,1000000000)),gq=int(number(q,"min_gq",10,0,1000000000));
    require(c.contains("runs")&&c["runs"].is_array()&&!c["runs"].empty()&&c["runs"].size()<=64,"reads requires 1..64 explicitly mapped paired-end runs");
    json inputs={{"reference",utf8(ref)}};std::set<std::string> ids,sample_set;std::vector<fs::path> fastqs;uint64_t bytes=0;std::map<std::pair<std::string,std::string>,std::vector<std::string>> libraries;
    if(c.contains("samples"))inputs["samples"]=utf8(source(c,"samples",base));
    auto tc=c.value("tools",json::object());keys(tc,{"fastp","bowtie2","bowtie2-build","samtools","bcftools"});auto deps=executable_path().parent_path().parent_path()/".deps/raw-tools";
    json tools=json::object();auto tool=[&](const std::string& name,const std::string& fallback){tools[name]={{"path",tc.value(name,fallback)}};};
    tool("fastp",utf8(deps/"fastp-1.3.3-windows-ucrt64/fastp.exe"));tool("bowtie2",utf8(deps/"bowtie2-2.5.5-mingw-x86_64/bowtie2-align-s.exe"));tool("bowtie2-build",utf8(deps/"bowtie2-2.5.5-mingw-x86_64/bowtie2-build-s.exe"));tool("samtools","samtools.exe");tool("bcftools","bcftools.exe");tools["popgen"]={{"path",utf8(executable_path())}};
    json tasks=json::array();auto task=[&](std::string id,json dependencies,std::vector<std::string> argv,json outputs,int cpu=1){if(dependencies.is_null())dependencies=json::array();tasks.push_back({{"id",id},{"kind","command"},{"pool","heavy"},{"depends_on",dependencies},{"memory_mb",memory},{"timeout_seconds",timeout},{"commands",json::array({{{"argv",argv},{"threads",cpu}}})},{"outputs",outputs}});};
    task("reference",{}, {"popgen","raw-reference","--input","{input:reference}","--out","{out}","--sha256",hash,"--max-bases",std::to_string(max_ref)},{"reference.fa","reference.fa.fai","autosomes.bed","ploidy.txt","reference.json"});tasks.back()["stdout"]="reference.json";
    task("index",{"reference"},{"bowtie2-build","--threads",std::to_string(threads),"-f","{task:reference}/reference.fa","{out}/reference"},{"reference.1.bt2","reference.2.bt2","reference.3.bt2","reference.4.bt2","reference.rev.1.bt2","reference.rev.2.bt2"},threads);
    size_t i=0;for(const auto& run:c["runs"]){keys(run,{"id","sample","library","read1","read2"});auto id=text(run,"id"),sample=text(run,"sample"),library=text(run,"library");for(const auto& name:{id,sample,library})identifier(name);require(ids.insert(id).second,"Duplicate run ID");sample_set.insert(sample);
        std::string n="r"+std::to_string(++i);for(const auto* mate:{"read1","read2"}){auto path=source(run,mate,base);require(fs::is_regular_file(path),"FASTQ input must be a regular file");for(const auto& previous:fastqs)require(!fs::equivalent(previous,path),"A FASTQ file is used by more than one run or mate");fastqs.push_back(path);auto size=fs::file_size(path);require(size>0&&size<=max_input-bytes,"FASTQ inputs exceed explicit byte budget");bytes+=size;inputs[n+"-"+mate]=utf8(path);}
        task(n+"-check",{"reference"},{"popgen","raw-fastq","--read1","{input:"+n+"-read1}","--read2","{input:"+n+"-read2}"},{"reads.json"});tasks.back()["stdout"]="reads.json";
        std::vector<std::string> trim={"fastp","-i","{input:"+n+"-read1}","-I","{input:"+n+"-read2}","-o","{out}/read1.fastq.gz","-O","{out}/read2.fastq.gz","--json","{out}/fastp.raw.json","--html","{out}/fastp.html","--thread",std::to_string(threads),"--length_required",std::to_string(length),"--qualified_quality_phred",std::to_string(quality),"--unqualified_percent_limit",std::to_string(unqualified),"--disable_trim_poly_g","--dont_eval_duplication"};if(!adapters)trim.push_back("--disable_adapter_trimming");
        task(n+"-trim",{n+"-check"},trim,{"read1.fastq.gz","read2.fastq.gz","fastp.raw.json","fastp.html"},threads+4);
        task(n+"-trim-check",{n+"-trim",n+"-check"},{"popgen","raw-fastq","--read1","{task:"+n+"-trim}/read1.fastq.gz","--read2","{task:"+n+"-trim}/read2.fastq.gz","--fastp-report","{task:"+n+"-trim}/fastp.raw.json","--before","{task:"+n+"-check}/reads.json","--report-out","{out}/fastp.json"},{"reads.json","fastp.json"});tasks.back()["stdout"]="reads.json";
        task(n+"-align",{"index",n+"-trim",n+"-trim-check"},{"bowtie2","--very-sensitive","--end-to-end","--no-mixed","--no-discordant","--seed","1","--reorder","-p",std::to_string(threads),"-X",std::to_string(fragment),"--rg-id",id,"--rg","SM:"+sample,"--rg","LB:"+library,"--rg","PL:ILLUMINA","-x","{task:index}/reference","-1","{task:"+n+"-trim}/read1.fastq.gz","-2","{task:"+n+"-trim}/read2.fastq.gz"},{"names.bam"},threads+1);
        tasks.back()["commands"].push_back({{"argv",{"samtools","sort","-n","-m","256M","-T","{out}/sort-tmp","-o","{out}/names.bam","-"}},{"threads",1}});
        task(n+"-fix",{n+"-align"},{"samtools","fixmate","-m","-u","{task:"+n+"-align}/names.bam","-"},{"coordinate.bam"});
        tasks.back()["commands"].push_back({{"argv",{"samtools","sort","-m","256M","-T","{out}/sort-tmp","-o","{out}/coordinate.bam","-"}},{"threads",1}});libraries[{sample,library}].push_back(n+"-fix");
    }
    metadata(c.contains("samples")?from_utf8(inputs["samples"].get<std::string>()):fs::path{},sample_set);
    std::vector<std::string> bam_args={"popgen","raw-bams","--reference","{task:reference}/reference.fa","--out","{out}"},alignment_paths;json bam_deps={"reference"};
    if(c.contains("samples"))bam_args.insert(bam_args.end(),{"--samples","{input:samples}"});
    i=0;for(const auto& [identity,runs]:libraries){auto n="lib"+std::to_string(++i);std::vector<std::string> merge={"samtools","merge","-o","{out}/merged.bam"};for(const auto& run:runs)merge.push_back("{task:"+run+"}/coordinate.bam");task(n+"-merge",runs,merge,{"merged.bam"});
        task(n+"-markdup",{n+"-merge"},{"samtools","markdup","-s","-f","{out}/duplicates.txt","-O","bam","{task:"+n+"-merge}/merged.bam","-"},{"alignment.bam","alignment.bam.csi","duplicates.txt"});
        tasks.back()["commands"].push_back({{"argv",{"samtools","view","-b","--write-index","-o","{out}/alignment.bam##idx##{out}/alignment.bam.csi","-"}},{"threads",1}});
        bam_deps.push_back(n+"-markdup");alignment_paths.push_back("{task:"+n+"-markdup}/alignment.bam");bam_args.insert(bam_args.end(),{"--bam",alignment_paths.back(),"--sample",identity.first,"--library",identity.second});
    }
    task("bams",bam_deps,bam_args,{"bams.list","samples.tsv","alignments.json"});tasks.back()["stdout"]="alignments.json";
    // This Windows build accepts Unicode argv paths, but not UTF-8 paths from -b lists.
    std::vector<std::string> pileup={"bcftools","mpileup","-Ou","-f","{task:reference}/reference.fa","-R","{task:reference}/autosomes.bed","-a","FORMAT/DP,FORMAT/AD","-q",std::to_string(mapq),"-Q",std::to_string(baseq),"-d",std::to_string(depth)};pileup.insert(pileup.end(),alignment_paths.begin(),alignment_paths.end());bam_deps.push_back("bams");
    task("call",bam_deps,pileup,{"cohort.bcf","cohort.bcf.csi"});
    tasks.back()["commands"].push_back({{"argv",{"bcftools","call","-m","-v","--ploidy-file","{task:reference}/ploidy.txt","-a","GQ","-Ob","-W","-o","{out}/cohort.bcf","-"}},{"threads",1}});
    task("normalize",{"reference","call"},{"bcftools","norm","-f","{task:reference}/reference.fa","-c","e","-m","-any","--multi-overlaps",".","-Ob","-o","{out}/normalized.bcf","{task:call}/cohort.bcf"},{"normalized.bcf"});
    task("mask",{"normalize"},{"popgen","mask","--input","{task:normalize}/normalized.bcf","--out","{out}/masked.bcf","--min-dp",std::to_string(dp),"--min-gq",std::to_string(gq)},{"masked.bcf","masked.bcf.csi","mask.json"});tasks.back()["stdout"]="mask.json";
    tasks.push_back({{"id","stats"},{"kind","stats"},{"depends_on",{"mask","bams"}},{"input","{task:mask}/masked.bcf"},{"samples","{task:bams}/samples.tsv"},{"hts_threads",1},{"memory_mb",memory},{"timeout_seconds",timeout}});
    // Copy and intermediate-file budgets are conservative reservations, not OS disk quotas.
    auto root=from_utf8(text(c,"work_dir"));if(root.is_relative())root=base/root;auto parent=fs::absolute(root);while(!fs::exists(parent))parent=parent.parent_path();
    uint64_t estimate=fs::file_size(ref)*12+bytes*16+67108864ULL;require(estimate<=scratch,"Scratch budget is below conservative reference/input estimate");require(fs::space(parent).available>=scratch,"Available disk is below requested scratch reservation");
    // Assembly label is recorded in the generated task arguments and command provenance.
    auto& argv=tasks[0]["commands"][0]["argv"];argv.push_back("--assembly");argv.push_back(assembly);
    return {{"schema_version",1},{"work_dir",text(c,"work_dir")},{"resources",c.value("resources",json{{"threads",8},{"memory_mb",10240}})},{"inputs",inputs},{"tools",tools},{"reference","reference"},{"tasks",tasks}};
}
}
