#include "popgen.hpp"
#include <htslib/vcf.h>
#include <algorithm>
#include <fstream>
#include <iomanip>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <stdexcept>
#include "workflow.hpp"
namespace pg {
void Counts::add(const Counts& b) {
    called += b.called;
    het += b.het;
    alt += b.alt;
    missing += b.missing;
    filtered += b.filtered;
    unsupported += b.unsupported;
}
std::string ratio(uint64_t numerator, uint64_t denominator) {
    if (!denominator) return "NA";
    std::ostringstream out;
    out << std::setprecision(12) << double(numerator) / double(denominator);
    return out.str();
}
bool autosome(const std::string& contig) {
    auto s = contig.starts_with("chr") ? contig.substr(3) : contig;
    for (int i = 1; i <= 22; ++i)
        if (s == std::to_string(i)) return true;
    return false;
}
std::vector<std::string> split_tsv(const std::string& line) {
    std::vector<std::string> cells;
    size_t start = 0;
    for (;;) {
        auto end = line.find('\t', start);
        cells.push_back(line.substr(start, end - start));
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return cells;
}
namespace {
constexpr const char* files[] = {"samples.tsv", "sites.tsv", "populations.tsv", "population_sites.tsv",
                                 "provenance.json"};
struct IntBuffer {
    int32_t* p = nullptr;
    int capacity = 0;
    ~IntBuffer() { free(p); }
};
struct Stage {
    fs::path path;
    bool owned = false, published = false;
    ~Stage() {
        if (owned && !published) {
            std::error_code ec;
            for (auto f : files) fs::remove(path / f, ec);
            fs::remove(path, ec);
        }
    }
};
std::ofstream output(const fs::path& path) {
    std::ofstream out(path, std::ios::binary);
    out.exceptions(std::ios::failbit | std::ios::badbit);
    return out;
}
std::vector<std::string> metadata(const fs::path& path, const bcf_hdr_t* header) {
    int n = bcf_hdr_nsamples(header);
    std::vector<std::string> result(n, "ALL");
    if (path.empty()) return result;
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("Cannot open sample metadata");
    std::string line;
    if (!std::getline(in, line)) throw std::runtime_error("Empty sample metadata");
    if (line.starts_with("\xEF\xBB\xBF")) line.erase(0, 3);
    if (!line.empty() && line.back() == '\r') line.pop_back();
    auto columns = split_tsv(line);
    if (std::set<std::string>(columns.begin(), columns.end()).size() != columns.size())
        throw std::runtime_error("Duplicate metadata columns");
    auto sid = std::find(columns.begin(), columns.end(), "sample"),
         pop = std::find(columns.begin(), columns.end(), "population");
    if (sid == columns.end() || pop == columns.end())
        throw std::runtime_error("Metadata requires sample and population columns");
    auto si = sid - columns.begin(), pi = pop - columns.begin();
    std::map<std::string, std::string> rows;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        auto c = split_tsv(line);
        if (c.size() != columns.size() || c[si].empty() || c[pi].empty())
            throw std::runtime_error("Malformed sample metadata row");
        for (const auto& cell : c)
            if (cell.find_first_of("\r\n") != std::string::npos) throw std::runtime_error("Invalid metadata cell");
        if (!rows.emplace(c[si], c[pi]).second) throw std::runtime_error("Duplicate metadata sample: " + c[si]);
    }
    if (in.bad()) throw std::runtime_error("Metadata read error");
    if (rows.size() != static_cast<size_t>(n))
        throw std::runtime_error("Metadata sample set differs from genotype header");
    for (int i = 0; i < n; ++i) {
        auto it = rows.find(header->samples[i]);
        if (it == rows.end()) throw std::runtime_error("Missing metadata sample: " + std::string(header->samples[i]));
        result[i] = it->second;
    }
    return result;
}
void columns(std::ostream& out, const Counts& c) {
    out << c.called << '\t' << c.het << '\t' << c.alt << '\t' << c.missing << '\t' << c.filtered << '\t'
        << c.unsupported << '\t' << ratio(c.het, c.called);
}
double expected(const Counts& c) {
    double p = double(c.alt) / (2.0 * double(c.called));
    return 2 * p * (1 - p);
}
std::string expected_text(const Counts& c) {
    if (!c.called) return "NA";
    std::ostringstream s;
    s << std::setprecision(12) << expected(c);
    return s.str();
}
const char* count_header =
    "called\theterozygous\talt_alleles\tmissing\tquality_filtered\tunsupported_ploidy\tobserved_heterozygosity";
void ensure_owned(const fs::path& target) {
    if (!fs::is_directory(target) || fs::is_symlink(fs::symlink_status(target)))
        throw std::runtime_error("Replacement target must be a regular result directory");
    auto manifest = json::parse(read_text(target / "provenance.json"));
    if (manifest.value("application", "") != "PopGenA" || manifest.value("status", "") != "complete")
        throw std::runtime_error("Refusing to replace an unrecognized output directory");
    std::set<std::string> allowed(std::begin(files), std::end(files));
    for (const auto& e : fs::directory_iterator(target))
        if (!allowed.contains(utf8(e.path().filename())) || !e.is_regular_file() || e.is_symlink())
            throw std::runtime_error("Output contains additional files; choose a new output directory");
}
bool within(const fs::path& file, const fs::path& dir) {
    auto relative = fs::relative(file, dir);
    return !relative.empty() && *relative.begin() != ".." && !relative.is_absolute();
}
}
json stats(const StatsOptions& o) {
    if (o.threads < 1 || o.threads > 8 || o.min_dp < 0 || o.min_gq < 0)
        throw std::runtime_error("Invalid statistics options");
    auto input = fs::canonical(o.input), target = fs::weakly_canonical(fs::absolute(o.out));
    fs::create_directories(target.parent_path());
    auto lock = exclusive_lock(target.parent_path() / ("." + utf8(target.filename()) + ".popgen.lock"));
    if (within(input, target) || (!o.samples.empty() && within(fs::canonical(o.samples), target)))
        throw std::runtime_error("Inputs cannot be inside the output directory");
    if (fs::exists(target)) {
        if (!o.replace) throw std::runtime_error("Output exists; use --replace for an owned PopGenA result");
        ensure_owned(target);
    }
    auto size = fs::file_size(input);
    auto modified = fs::last_write_time(input);
    std::string sample_hash = o.samples.empty() ? "" : sha256(o.samples);
    using File = std::unique_ptr<htsFile, decltype(&hts_close)>;
    using Header = std::unique_ptr<bcf_hdr_t, decltype(&bcf_hdr_destroy)>;
    using Record = std::unique_ptr<bcf1_t, decltype(&bcf_destroy)>;
    File in(hts_open(utf8(input).c_str(), "r"), &hts_close);
    if (!in) throw std::runtime_error("Cannot open genotype input");
    auto format = hts_get_format(in.get());
    if (!format || (format->format != vcf && format->format != bcf))
        throw std::runtime_error("Input must be VCF or BCF");
    if (hts_set_threads(in.get(), o.threads) != 0) throw std::runtime_error("Cannot configure HTS threads");
    Header header(bcf_hdr_read(in.get()), &bcf_hdr_destroy);
    if (!header || bcf_hdr_nsamples(header.get()) == 0) throw std::runtime_error("Genotype header has no samples");
    int n = bcf_hdr_nsamples(header.get());
    std::set<std::string> sample_ids;
    for (int i = 0; i < n; ++i)
        if (!sample_ids.emplace(header->samples[i]).second) throw std::runtime_error("Duplicate genotype sample ID");
    auto groups = metadata(o.samples, header.get());
    std::map<std::string, size_t> group_map;
    for (const auto& g : groups) group_map.emplace(g, 0);
    size_t index = 0;
    for (auto& [name, id] : group_map) {
        (void)name;
        id = index++;
    }
    std::vector<size_t> group_index;
    for (const auto& g : groups) group_index.push_back(group_map.at(g));
    std::vector<Counts> sample_counts(n), population_counts(group_map.size());
    std::vector<double> expected_sums(group_map.size());
    std::vector<uint64_t> expected_sites(group_map.size());
    fs::create_directories(target.parent_path());
    Stage stage{target.parent_path() / from_utf8(".popgen-stage-" + unique_id())};
    if (!fs::create_directory(stage.path)) throw std::runtime_error("Cannot create temporary output directory");
    stage.owned = true;
    auto sites = output(stage.path / "sites.tsv"), pop_sites = output(stage.path / "population_sites.tsv");
    sites << "chrom\tpos\tid\tref\talt\t" << count_header << "\talt_frequency\texpected_heterozygosity\n";
    pop_sites << "chrom\tpos\tpopulation\t" << count_header << "\talt_frequency\texpected_heterozygosity\n";
    Record record(bcf_init(), &bcf_destroy);
    if (!record) throw std::bad_alloc();
    IntBuffer gt, dp, gq;
    uint64_t records = 0, eligible = 0, skip_contig = 0, skip_variant = 0, skip_filter = 0;
    int status = 0;
    while ((status = bcf_read(in.get(), header.get(), record.get())) == 0) {
        ++records;
        if (record->errcode) throw std::runtime_error("Invalid VCF/BCF record at record " + std::to_string(records));
        if (bcf_unpack(record.get(), BCF_UN_ALL) < 0) throw std::runtime_error("Cannot unpack genotype record");
        const char* chrom = bcf_hdr_id2name(header.get(), record->rid);
        if (!chrom || !autosome(chrom)) {
            ++skip_contig;
            continue;
        }
        auto base = [](const char* a) {
            return a && a[0] && !a[1] && std::string("ACGT").find(a[0]) != std::string::npos;
        };
        if (record->n_allele != 2 || !base(record->d.allele[0]) || !base(record->d.allele[1]) ||
            record->d.allele[0][0] == record->d.allele[1][0]) {
            ++skip_variant;
            continue;
        }
        bool pass = true;
        for (int i = 0; i < record->d.n_flt; ++i)
            if (std::string(bcf_hdr_int2id(header.get(), BCF_DT_ID, record->d.flt[i])) != "PASS") pass = false;
        if (!pass) {
            ++skip_filter;
            continue;
        }
        ++eligible;
        int ngt = bcf_get_genotypes(header.get(), record.get(), &gt.p, &gt.capacity);
        if (ngt == -2 || ngt == -4 || (ngt > 0 && ngt % n)) throw std::runtime_error("Invalid GT field");
        int ndp = o.min_dp ? bcf_get_format_int32(header.get(), record.get(), "DP", &dp.p, &dp.capacity) : 0;
        int ngq = o.min_gq ? bcf_get_format_int32(header.get(), record.get(), "GQ", &gq.p, &gq.capacity) : 0;
        auto check_quality = [n](int total) {
            if (total == -2 || total == -4 || (total > 0 && total != n))
                throw std::runtime_error("DP/GQ must be scalar Integer FORMAT fields");
        };
        check_quality(ndp);
        check_quality(ngq);
        auto quality = [](int threshold, int total, const IntBuffer& values, int i) {
            return !threshold || (total > 0 && values.p[i] != bcf_int32_missing &&
                                  values.p[i] != bcf_int32_vector_end && values.p[i] >= threshold);
        };
        Counts total;
        std::vector<Counts> per_group(group_map.size());
        for (int i = 0; i < n; ++i) {
            Counts c;
            int ploidy = 0, alternate = 0;
            bool missing = ngt <= 0;
            if (ngt > 0) {
                int stride = ngt / n;
                for (int j = 0; j < stride; ++j) {
                    auto value = gt.p[i * stride + j];
                    if (value == bcf_int32_vector_end) break;
                    ++ploidy;
                    if (bcf_gt_is_missing(value)) {
                        missing = true;
                        continue;
                    }
                    int allele = bcf_gt_allele(value);
                    if (allele < 0 || allele > 1) throw std::runtime_error("GT allele index outside REF/ALT range");
                    alternate += allele;
                }
            }
            if (missing)
                c.missing = 1;
            else if (ploidy != 2)
                c.unsupported = 1;
            else if (!quality(o.min_dp, ndp, dp, i) || !quality(o.min_gq, ngq, gq, i))
                c.filtered = 1;
            else {
                c.called = 1;
                c.het = alternate == 1;
                c.alt = alternate;
            }
            sample_counts[i].add(c);
            per_group[group_index[i]].add(c);
            total.add(c);
        }
        sites << chrom << '\t' << record->pos + 1 << '\t' << record->d.id << '\t' << record->d.allele[0] << '\t'
              << record->d.allele[1] << '\t';
        columns(sites, total);
        sites << '\t' << ratio(total.alt, 2 * total.called) << '\t' << expected_text(total) << '\n';
        for (const auto& [name, id] : group_map) {
            const auto& c = per_group[id];
            population_counts[id].add(c);
            if (c.called) {
                expected_sums[id] += expected(c);
                ++expected_sites[id];
            }
            pop_sites << chrom << '\t' << record->pos + 1 << '\t' << name << '\t';
            columns(pop_sites, c);
            pop_sites << '\t' << ratio(c.alt, 2 * c.called) << '\t' << expected_text(c) << '\n';
        }
    }
    if (status != -1) throw std::runtime_error("Malformed or truncated genotype input");
    if (hts_check_EOF(in.get()) == 0) throw std::runtime_error("Compressed input lacks its EOF marker");
    if (hts_close(in.release()) != 0) throw std::runtime_error("Genotype input close failed");
    if (!records || !eligible) throw std::runtime_error("No eligible autosomal biallelic SNP records");
    sites.close();
    pop_sites.close();
    auto samples = output(stage.path / "samples.tsv");
    samples << "sample\tpopulation\t" << count_header << "\tcall_rate\n";
    for (int i = 0; i < n; ++i) {
        samples << header->samples[i] << '\t' << groups[i] << '\t';
        columns(samples, sample_counts[i]);
        samples << '\t' << ratio(sample_counts[i].called, eligible) << '\n';
    }
    samples.close();
    auto populations = output(stage.path / "populations.tsv");
    populations << "population\t" << count_header << "\tsites_with_calls\tmean_expected_heterozygosity\n";
    for (const auto& [name, id] : group_map) {
        populations << name << '\t';
        columns(populations, population_counts[id]);
        populations << '\t' << expected_sites[id] << '\t';
        if (expected_sites[id])
            populations << std::setprecision(12) << expected_sums[id] / double(expected_sites[id]);
        else
            populations << "NA";
        populations << '\n';
    }
    populations.close();
    auto digest = sha256(input);
    if (fs::file_size(input) != size || fs::last_write_time(input) != modified ||
        (!o.samples.empty() && sha256(o.samples) != sample_hash))
        throw std::runtime_error("Input changed during analysis");
    json report = {
        {"application", "PopGenA"},
        {"version", version},
        {"schema_version", 1},
        {"status", "complete"},
        {"platform", "linux-x86_64"},
        {"htslib", hts_version()},
        {"input", {{"path", utf8(input)}, {"sha256", digest}, {"size_bytes", size}}},
        {"metadata",
         o.samples.empty() ? json(nullptr) : json{{"path", utf8(fs::canonical(o.samples))}, {"sha256", sample_hash}}},
        {"options",
         {{"threads", o.threads},
          {"min_dp", o.min_dp},
          {"min_gq", o.min_gq},
          {"contigs", "1..22 or chr1..chr22"},
          {"site_filter", "PASS or unfiltered dot"}}},
        {"records", records},
        {"eligible_sites", eligible},
        {"sample_count", n},
        {"population_count", group_map.size()},
        {"skipped",
         {{"non_autosomal", skip_contig}, {"not_biallelic_snp", skip_variant}, {"site_filter", skip_filter}}}};
    report["outputs"] = json::object();
    for (auto f : files)
        if (std::string(f) != "provenance.json") report["outputs"][f] = sha256(stage.path / f);
    write_text(stage.path / "provenance.json", report.dump(2) + "\n");
    fs::path backup;
    if (fs::exists(target)) {
        ensure_owned(target);
        backup = target.parent_path() / from_utf8(".popgen-backup-" + unique_id());
        fs::rename(target, backup);
    }
    try {
        fs::rename(stage.path, target);
        stage.published = true;
    } catch (...) {
        if (!backup.empty()) fs::rename(backup, target);
        throw;
    }
    if (!backup.empty()) {
        std::error_code ec;
        for (auto f : files) fs::remove(backup / f, ec);
        fs::remove(backup, ec);
    }
    return report;
}
}
