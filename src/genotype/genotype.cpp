#include "genotype/genotype.hpp"
#include "core/process.hpp"
#include "stats/stats.hpp"
#include <htslib/vcf.h>
#include <algorithm>
#include <cmath>
#include <fstream>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <stdexcept>

namespace pg {
namespace {
void need(bool ok, const std::string& message) {
    if (!ok) throw std::runtime_error(message);
}
void keys(const json& j, std::initializer_list<const char*> names) {
    need(j.is_object(), "Genotype configuration requires objects");
    std::set<std::string> allowed(names.begin(), names.end());
    for (const auto& [k, v] : j.items()) {
        (void)v;
        need(allowed.contains(k), "Unknown genotype configuration key: " + k);
    }
}
int integer(const json& j, const char* key, int fallback, int lo, int hi) {
    if (!j.contains(key)) return fallback;
    need(j[key].is_number_integer(), std::string(key) + " must be integer");
    auto n = j[key].get<int64_t>();
    need(n >= lo && n <= hi, std::string(key) + " out of range");
    return int(n);
}
double real(const json& j, const char* key, double fallback, double lo, double hi) {
    if (!j.contains(key)) return fallback;
    need(j[key].is_number(), std::string(key) + " must be numeric");
    auto n = j[key].get<double>();
    need(std::isfinite(n) && n >= lo && n <= hi, std::string(key) + " out of range");
    return n;
}
std::string str(const json& j, const char* key) {
    need(j.contains(key) && j[key].is_string(), std::string(key) + " must be a string");
    auto s = j[key].get<std::string>();
    need(!s.empty() && s.find_first_of("\r\n\t") == std::string::npos && s.find('\0') == std::string::npos,
         "Invalid " + std::string(key));
    return s;
}
std::string num(double n) {
    std::ostringstream s;
    s.precision(12);
    s << n;
    return s.str();
}
struct Table {
    std::ifstream file;
    std::vector<std::string> header;
    explicit Table(const fs::path& path) : file(path) {
        need(bool(file), "Cannot open table: " + utf8(path));
        std::string line;
        while (std::getline(file, line)) {
            if (line.starts_with("##")) continue;
            header = cells(line);
            break;
        }
        need(!header.empty(), "Empty table: " + utf8(path));
        if (header[0].starts_with('#')) header[0].erase(0, 1);
        need(std::set<std::string>(header.begin(), header.end()).size() == header.size(), "Duplicate table columns");
    }
    static std::vector<std::string> cells(const std::string& line) {
        std::istringstream s(line);
        std::vector<std::string> c;
        std::string v;
        while (s >> v) c.push_back(v);
        return c;
    }
    size_t col(const std::string& name) const {
        auto it = std::find(header.begin(), header.end(), name);
        need(it != header.end(), "Missing column: " + name);
        return it - header.begin();
    }
    bool row(std::vector<std::string>& c) {
        std::string line;
        if (!std::getline(file, line)) {
            need(!file.bad(), "Table read failure");
            return false;
        }
        c = cells(line);
        need(c.size() == header.size(), "Malformed table row");
        return true;
    }
};
std::vector<std::string> sample_ids(const fs::path& path) {
    Table t(path);
    auto iid = t.col("IID"), fid = t.col("FID");
    std::vector<std::string> ids, row;
    std::set<std::string> seen;
    while (t.row(row)) {
        need(row[iid] == row[fid] && seen.insert(row[iid]).second,
             "Sample identity changed/duplicated in PLINK output");
        ids.push_back(row[iid]);
    }
    need(!ids.empty(), "No samples remain");
    return ids;
}
double finite_value(const std::string& s) {
    size_t pos = 0;
    double n = std::stod(s, &pos);
    need(pos == s.size() && std::isfinite(n), "Nonfinite or malformed numeric result");
    return n;
}
}

json expand_genotypes(const json& c, const fs::path& base) {
    keys(c, {"schema_version", "workflow_type", "work_dir", "assembly", "input", "reference", "reference_index",
             "samples", "resources", "tools", "qc", "analysis"});
    need(integer(c, "schema_version", 0, 1, 1) == 1, "Genotype schema_version must be 1");
    need(str(c, "workflow_type") == "genotypes", "Unknown workflow_type");
    auto assembly = str(c, "assembly");
    auto reference = from_utf8(str(c, "reference")), index = from_utf8(str(c, "reference_index"));
    if (reference.is_relative()) reference = base / reference;
    if (index.is_relative()) index = base / index;
    need(fs::canonical(index) == fs::canonical(from_utf8(utf8(reference) + ".fai")),
         "reference_index must be the reference FASTA's adjacent .fai");
    auto q = c.value("qc", json::object());
    keys(q, {"min_dp", "min_gq", "sample_missing", "variant_missing"});
    int dp = integer(q, "min_dp", 0, 0, 1000000000), gq = integer(q, "min_gq", 0, 0, 1000000000);
    auto mind = real(q, "sample_missing", 0.1, 0, 1), geno = real(q, "variant_missing", 0.1, 0, 1);
    auto a = c.value("analysis", json::object());
    keys(a, {"pcs", "pca_maf", "kinship_maf", "kinship_threshold", "relatedness_policy", "ld_window", "ld_step",
             "ld_r2", "threads", "memory_mb", "timeout_seconds"});
    // PLINK2 requires at least 640 MiB workspace, plus our 512 MiB process reserve.
    int pcs = integer(a, "pcs", 10, 1, 50), threads = integer(a, "threads", 2, 1, 6),
        memory = integer(a, "memory_mb", 2048, 1152, 10240);
    int timeout = integer(a, "timeout_seconds", 3600, 1, 604800), window = integer(a, "ld_window", 50, 2, 100000),
        step = integer(a, "ld_step", std::min(5, window), 1, window);
    auto maf = real(a, "pca_maf", 0.05, 0.000001, 0.5), kingmaf = real(a, "kinship_maf", 0.05, 0.000001, 0.5),
         r2 = real(a, "ld_r2", 0.2, 0.000001, 1), threshold = real(a, "kinship_threshold", 0.0884, 0, 0.5);
    auto policy = str(a, "relatedness_policy");
    need(policy == "retain" || policy == "exclude", "Set relatedness_policy explicitly to retain or exclude");
    auto tool_config = c.value("tools", json::object());
    keys(tool_config, {"bcftools", "plink2"});
    json tools = {{"bcftools", {{"path", tool_config.value("bcftools", std::string("bcftools"))}}},
                  {"plink2", {{"path", tool_config.value("plink2", std::string("plink2"))}}},
                  {"popgen", {{"path", utf8(executable_path())}}}};
    json inputs = {{"cohort", str(c, "input")},
                   {"reference", str(c, "reference")},
                   {"reference-index", str(c, "reference_index")}};
    if (c.contains("samples")) inputs["samples"] = str(c, "samples");
    json tasks = json::array();
    auto task = [&](std::string id, json deps, std::vector<std::string> args, json outputs, int cpu = 1) {
        if (deps.is_null()) deps = json::array();
        tasks.push_back({{"id", id},
                         {"kind", "command"},
                         {"pool", "heavy"},
                         {"depends_on", deps},
                         {"memory_mb", memory},
                         {"timeout_seconds", timeout},
                         {"commands", json::array({{{"argv", args}, {"threads", cpu}}})},
                         {"outputs", outputs}});
    };
    auto plink = [&](std::string id, json deps, std::vector<std::string> args, json outputs) {
        args.insert(args.begin(), "plink2");
        args.insert(args.end(), {"--threads", std::to_string(threads), "--memory", std::to_string(memory - 512),
                                 "require", "--seed", "1", "--out", "{out}/data"});
        task(id, deps, args, outputs, threads);
    };
    const json pgen = {"data.pgen", "data.pvar", "data.psam", "data.log"};
    task("normalize", {},
         {"bcftools", "norm", "-f", "{input:reference}", "-c", "e", "-m", "-any", "--multi-overlaps", ".", "-Ob", "-o",
          "{out}/normalized.bcf", "{input:cohort}"},
         {"normalized.bcf"});
    task("mask", {"normalize"},
         {"popgen", "mask", "--input", "{task:normalize}/normalized.bcf", "--out", "{out}/masked.bcf", "--min-dp",
          std::to_string(dp), "--min-gq", std::to_string(gq)},
         {"masked.bcf", "masked.bcf.csi", "mask.json"});
    tasks.back()["stdout"] = "mask.json";
    plink("import", {"mask"},
          {"--bcf", "{task:mask}/masked.bcf", "--double-id", "--set-all-var-ids", "@:#:$r:$a", "--make-pgen"}, pgen);
    plink("missing", {"import"}, {"--pfile", "{task:import}/data", "--missing"},
          {"data.smiss", "data.vmiss", "data.log"});
    plink("sample-qc", {"import"}, {"--pfile", "{task:import}/data", "--mind", num(mind), "--make-pgen"}, pgen);
    plink("site-qc", {"sample-qc"}, {"--pfile", "{task:sample-qc}/data", "--geno", num(geno), "--make-pgen"}, pgen);
    plink("king", {"site-qc"},
          {"--pfile", "{task:site-qc}/data", "--maf", num(kingmaf), "--make-king-table", "cols=id,nsnp,kinship",
           "--king-table-filter", num(threshold)},
          {"data.kin0", "data.log"});
    std::vector<std::string> select = {"popgen",      "cohort-select",
                                       "--original",  "{task:import}/data.psam",
                                       "--psam",      "{task:site-qc}/data.psam",
                                       "--kinship",   "{task:king}/data.kin0",
                                       "--policy",    policy,
                                       "--threshold", num(threshold),
                                       "--out",       "{out}"};
    if (c.contains("samples")) select.insert(select.end(), {"--samples", "{input:samples}"});
    task("select", {"import", "site-qc", "king"}, select, {"keep.tsv", "samples.tsv", "selection.json"});
    auto retained = pgen;
    retained.push_back("data.vcf.gz");
    // PLINK exports bgzipped VCF and bcftools writes the indexed BCF. (The earlier Windows PLINK
    // build embedded CR in the last sample ID of direct BCF exports.) The route is kept because the
    // validated real-data results were produced through it.
    plink("retained", {"site-qc", "select"},
          {"--pfile", "{task:site-qc}/data", "--keep", "{task:select}/keep.tsv", "--make-pgen", "--export", "vcf",
           "bgz", "id-paste=iid"},
          retained);
    task("bcf", {"retained"},
         {"bcftools", "view", "-Ob", "-W", "-o", "{out}/cohort.bcf", "{task:retained}/data.vcf.gz"},
         {"cohort.bcf", "cohort.bcf.csi"});
    tasks.push_back({{"id", "stats"},
                     {"kind", "stats"},
                     {"depends_on", {"bcf", "select"}},
                     {"input", "{task:bcf}/cohort.bcf"},
                     {"samples", "{task:select}/samples.tsv"},
                     {"hts_threads", 1},
                     {"memory_mb", memory}});
    plink("prune", {"retained"},
          {"--pfile", "{task:retained}/data", "--maf", num(maf), "--indep-pairwise", std::to_string(window),
           std::to_string(step), num(r2)},
          {"data.prune.in", "data.log"});
    // Exact PCA is bounded by a separate validation/preflight task, not silently allowed at large N.
    task("pca-check", {"retained"},
         {"popgen", "pca-check", "--psam", "{task:retained}/data.psam", "--pcs", std::to_string(pcs)}, {"check.json"});
    tasks.back()["stdout"] = "check.json";
    plink("pca", {"retained", "prune", "pca-check"},
          {"--pfile", "{task:retained}/data", "--extract", "{task:prune}/data.prune.in", "--pca", std::to_string(pcs),
           "meanimpute"},
          {"data.eigenvec", "data.eigenval", "data.log"});
    task("validate", {"retained", "pca", "bcf", "prune"},
         {"popgen", "pca-check", "--psam", "{task:retained}/data.psam", "--pcs", std::to_string(pcs), "--vectors",
          "{task:pca}/data.eigenvec", "--values", "{task:pca}/data.eigenval", "--bcf", "{task:bcf}/cohort.bcf",
          "--markers", "{task:prune}/data.prune.in"},
         {"validation.json"});
    tasks.back()["stdout"] = "validation.json";
    // Preserve the user's assembly label alongside the exact reference identity.
    for (auto& t : tasks)
        if (t["kind"] == "command" && t["id"] == "select") {
            auto& argv = t["commands"][0]["argv"];
            argv.push_back("--assembly");
            argv.push_back(assembly);
        }
    return {{"schema_version", 1},
            {"work_dir", str(c, "work_dir")},
            {"resources", c.value("resources", json{{"threads", 8}, {"memory_mb", 10240}})},
            {"inputs", inputs},
            {"tools", tools},
            {"reference", "reference"},
            {"tasks", tasks}};
}

json select_cohort(const fs::path& original, const fs::path& psam, const fs::path& kinship, const fs::path& metadata,
                   const fs::path& out, const std::string& policy, double threshold) {
    need(policy == "retain" || policy == "exclude", "Invalid relatedness policy");
    need(std::isfinite(threshold) && threshold >= 0 && threshold <= 0.5, "Invalid kinship threshold");
    auto all = sample_ids(original), ids = sample_ids(psam);
    std::set<std::string> source(all.begin(), all.end()), current(ids.begin(), ids.end());
    for (const auto& id : ids) need(source.contains(id), "QC introduced an unknown sample");
    std::map<std::string, std::string> groups;
    for (const auto& id : all) groups[id] = "ALL";
    if (!metadata.empty()) {
        std::ifstream in(metadata);
        need(bool(in), "Cannot open metadata");
        std::string line;
        need(bool(std::getline(in, line)), "Empty metadata");
        if (line.starts_with("\xEF\xBB\xBF")) line.erase(0, 3);
        if (!line.empty() && line.back() == '\r') line.pop_back();
        auto header = split_tsv(line);
        auto si = std::find(header.begin(), header.end(), "sample"),
             pi = std::find(header.begin(), header.end(), "population");
        need(si != header.end() && pi != header.end() &&
                 std::set<std::string>(header.begin(), header.end()).size() == header.size(),
             "Metadata requires unique sample/population columns");
        groups.clear();
        while (std::getline(in, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            auto row = split_tsv(line);
            need(row.size() == header.size(), "Malformed metadata row");
            auto id = row[si - header.begin()], group = row[pi - header.begin()];
            need(source.contains(id) && !group.empty() && groups.emplace(id, group).second,
                 "Unknown/duplicate/empty metadata sample or population");
        }
        need(!in.bad() && groups.size() == source.size(), "Metadata must exactly match original sample set");
    }
    Table k(kinship);
    auto i1 = k.col("IID1"), i2 = k.col("IID2"), coef = k.col("KINSHIP");
    std::vector<std::string> row;
    std::set<std::pair<std::string, std::string>> pairs;
    while (k.row(row)) {
        need(current.contains(row[i1]) && current.contains(row[i2]) && row[i1] != row[i2],
             "Invalid kinship sample identity");
        auto value = finite_value(row[coef]);
        if (value >= threshold) pairs.emplace(std::min(row[i1], row[i2]), std::max(row[i1], row[i2]));
    }
    std::map<std::string, std::string> excluded;
    if (policy == "exclude")
        for (const auto& [a, b] : pairs)
            if (!excluded.contains(a) && !excluded.contains(b)) excluded[b] = a;
    fs::create_directories(out);
    for (const auto* name : {"keep.tsv", "samples.tsv", "selection.json"})
        need(!fs::exists(out / name), "Selection output already exists");
    std::string keep = "#FID\tIID\n", samples = "sample\tpopulation\n";
    json retained = json::array(), removed = json::array(), failed = json::array();
    for (const auto& id : ids)
        if (!excluded.contains(id)) {
            keep += id + '\t' + id + '\n';
            samples += id + '\t' + groups.at(id) + '\n';
            retained.push_back(id);
        } else
            removed.push_back({{"sample", id}, {"related_to_retained_or_earlier_sample", excluded.at(id)}});
    for (const auto& id : all)
        if (!current.contains(id)) failed.push_back(id);
    need(retained.size() >= 3, "Fewer than three samples remain after QC/relatedness selection");
    json result = {{"policy", policy},
                   {"threshold", threshold},
                   {"reported_pairs", pairs.size()},
                   {"retained", retained},
                   {"relatedness_excluded", removed},
                   {"sample_qc_excluded", failed},
                   {"algorithm", policy == "retain" ? "retain all QC-passing samples"
                                                    : "sorted-pair greedy: exclude lexicographically later ID when "
                                                      "both endpoints remain; not a maximum independent set"}};
    write_text(out / "keep.tsv", keep);
    write_text(out / "samples.tsv", samples);
    write_text(out / "selection.json", result.dump(2) + "\n");
    return result;
}

json validate_pca(const fs::path& psam, const fs::path& vectors, const fs::path& values, int pcs, const fs::path& bcf,
                  const fs::path& markers) {
    auto ids = sample_ids(psam);
    need(pcs >= 1 && size_t(pcs) < ids.size(), "PC count must be smaller than retained sample count");
    need(ids.size() <= 5000,
         "Exact PCA is limited to 5000 samples; approximate/scaling workflow is not implemented yet");
    json result = {{"samples", ids.size()},
                   {"pcs", pcs},
                   {"method", "PLINK2 exact variance-standardized PCA with mean imputation"}};
    if (vectors.empty() && values.empty()) return result;
    need(!vectors.empty() && !values.empty(), "Both eigenvector and eigenvalue files are required");
    std::ifstream val(values);
    need(bool(val), "Cannot open eigenvalues");
    std::string line;
    std::vector<double> eigenvalues;
    while (std::getline(val, line)) {
        auto cells = Table::cells(line);
        need(cells.size() == 1, "Invalid eigenvalue row");
        auto n = finite_value(cells[0]);
        need(n > 0, "PCA has a zero/negative eigenvalue");
        if (!eigenvalues.empty()) need(n <= eigenvalues.back() + 1e-8, "Eigenvalues are not descending");
        eigenvalues.push_back(n);
    }
    need(!val.bad() && eigenvalues.size() == size_t(pcs), "Unexpected PC count");
    Table t(vectors);
    auto iid = t.col("IID"), fid = t.col("FID");
    std::set<std::string> remaining(ids.begin(), ids.end());
    std::vector<std::string> row;
    std::vector<std::vector<double>> dot(pcs, std::vector<double>(pcs, 0));
    std::map<std::string, std::vector<double>> by_sample;
    while (t.row(row)) {
        need(row[iid] == row[fid] && remaining.erase(row[iid]) == 1, "PCA sample identity mismatch");
        std::vector<double> pc;
        for (int i = 0; i < pcs; ++i) pc.push_back(finite_value(row[t.col("PC" + std::to_string(i + 1))]));
        by_sample[row[iid]] = pc;
        for (int i = 0; i < pcs; ++i)
            for (int j = 0; j <= i; ++j) dot[i][j] += pc[i] * pc[j];
    }
    need(remaining.empty(), "PCA output omitted samples");
    for (int i = 0; i < pcs; ++i)
        for (int j = 0; j <= i; ++j)
            need(std::abs(dot[i][j] - (i == j ? 1.0 : 0.0)) < 0.002,
                 "PCA vectors are not orthonormal within output precision");
    if (!bcf.empty() || !markers.empty()) {
        need(!bcf.empty() && !markers.empty(), "BCF and marker list must be provided together");
        std::ifstream marker_file(markers);
        need(bool(marker_file), "Cannot open PCA marker list");
        std::set<std::string> selected;
        while (std::getline(marker_file, line)) {
            auto cells = Table::cells(line);
            need(cells.size() == 1 && selected.insert(cells[0]).second, "Invalid/duplicate PCA marker");
        }
        need(!marker_file.bad() && !selected.empty(), "Empty/unreadable PCA marker list");
        size_t count = selected.size();
        using File = std::unique_ptr<htsFile, decltype(&hts_close)>;
        using Header = std::unique_ptr<bcf_hdr_t, decltype(&bcf_hdr_destroy)>;
        using Record = std::unique_ptr<bcf1_t, decltype(&bcf_destroy)>;
        File input(hts_open(utf8(bcf).c_str(), "rb"), &hts_close);
        need(bool(input), "Cannot open PCA validation BCF");
        Header h(bcf_hdr_read(input.get()), &bcf_hdr_destroy);
        need(bool(h) && bcf_hdr_nsamples(h.get()) == int(ids.size()), "PCA validation sample count differs");
        std::vector<std::vector<double>> v, predicted(ids.size(), std::vector<double>(pcs, 0));
        std::set<std::string> seen;
        for (size_t i = 0; i < ids.size(); ++i) {
            std::string id = h->samples[i];
            need(by_sample.contains(id) && seen.insert(id).second, "PCA validation sample IDs differ");
            v.push_back(by_sample.at(id));
        }
        Record record(bcf_init(), &bcf_destroy);
        need(bool(record), "Cannot allocate PCA validation record");
        struct Buffer {
            int32_t* p = nullptr;
            int capacity = 0;
            ~Buffer() { free(p); }
        } gt;
        std::vector<double> dosage(ids.size());
        int status;
        while ((status = bcf_read(input.get(), h.get(), record.get())) == 0) {
            need(!record->errcode && bcf_unpack(record.get(), BCF_UN_ALL) == 0, "Malformed PCA validation BCF");
            if (!selected.erase(record->d.id)) continue;
            need(record->n_allele == 2, "Nonbiallelic PCA marker");
            int n = bcf_get_genotypes(h.get(), record.get(), &gt.p, &gt.capacity);
            need(n == int(ids.size() * 2), "Nondiploid PCA marker");
            double alt = 0, called = 0;
            for (size_t i = 0; i < ids.size(); ++i) {
                auto x = gt.p[i * 2], y = gt.p[i * 2 + 1];
                if (bcf_gt_is_missing(x) || bcf_gt_is_missing(y)) {
                    dosage[i] = -1;
                    continue;
                }
                need(x >= 0 && y >= 0 && bcf_gt_allele(x) <= 1 && bcf_gt_allele(y) <= 1, "Invalid PCA genotype");
                dosage[i] = bcf_gt_allele(x) + bcf_gt_allele(y);
                alt += dosage[i];
                ++called;
            }
            need(called > 0, "All-missing PCA marker");
            double p = alt / (2 * called);
            need(p > 0 && p < 1, "Monomorphic PCA marker");
            double scale = std::sqrt(2 * p * (1 - p));
            std::vector<double> projection(pcs, 0);
            for (size_t i = 0; i < ids.size(); ++i) {
                dosage[i] = dosage[i] < 0 ? 0 : (dosage[i] - 2 * p) / scale;
                for (int j = 0; j < pcs; ++j) projection[j] += dosage[i] * v[i][j];
            }
            for (size_t i = 0; i < ids.size(); ++i)
                for (int j = 0; j < pcs; ++j) predicted[i][j] += dosage[i] * projection[j] / count;
        }
        need(status == -1 && hts_check_EOF(input.get()) == 1 && selected.empty(), "PCA marker list/BCF incomplete");
        std::vector<double> residual(pcs, 0);
        for (size_t i = 0; i < ids.size(); ++i)
            for (int j = 0; j < pcs; ++j) {
                auto e = predicted[i][j] - eigenvalues[j] * v[i][j];
                residual[j] += e * e;
            }
        for (int j = 0; j < pcs; ++j) {
            residual[j] = std::sqrt(residual[j]) / eigenvalues[j];
            need(residual[j] < 0.001,
                 "PCA eigenpair differs from independently streamed standardized genotype covariance");
        }
        result["markers"] = count;
        result["relative_eigenpair_residual"] = residual;
    }
    result["eigenvalues"] = eigenvalues;
    result["validated"] = true;
    return result;
}
}
