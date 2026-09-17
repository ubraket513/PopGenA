#include "workflow/workflow.hpp"
#include "core/process.hpp"
#include "genotype/genotype.hpp"
#include "reads/reads.hpp"
#include <algorithm>
#include <chrono>
#include <functional>
#include <iostream>
#include <regex>
#include <set>
#include <stdexcept>

namespace pg {
namespace {
const std::vector<std::string> stats_outputs = {"samples.tsv", "sites.tsv", "populations.tsv", "population_sites.tsv",
                                                "provenance.json"};
void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}
void keys(const json& object, const std::set<std::string>& allowed) {
    require(object.is_object(), "Expected JSON object");
    for (const auto& [key, value] : object.items()) {
        (void)value;
        require(allowed.contains(key), "Unknown configuration key: " + key);
    }
}
int number(const json& object, const char* key, int fallback, int low, int high) {
    if (!object.contains(key)) return fallback;
    require(object[key].is_number_integer(), std::string(key) + " must be an integer");
    auto value = object[key].get<int64_t>();
    require(value >= low && value <= high, std::string(key) + " outside supported range");
    return static_cast<int>(value);
}
std::string text(const json& value) {
    require(value.is_string(), "Expected a string");
    auto s = value.get<std::string>();
    require(s.find('\0') == std::string::npos && s.find('\n') == std::string::npos && s.find('\r') == std::string::npos,
            "Control character in configuration string");
    return s;
}
void identifier(const std::string& id) {
    static const std::regex pattern("[a-z][a-z0-9_-]{0,47}");
    require(std::regex_match(id, pattern), "IDs must match [a-z][a-z0-9_-]{0,47}: " + id);
}
fs::path relative_output(const std::string& name) {
    require(!name.empty() && name.find_first_of(":\\*?\"<>|") == std::string::npos, "Invalid output path: " + name);
    auto p = from_utf8(name);
    require(!p.is_absolute() && !p.has_root_name(), "Output must be relative");
    for (const auto& component : p) {
        auto s = utf8(component);
        require(s != "." && s != ".." && !s.empty(), "Unsafe output component: " + name);
    }
    return p;
}
// Work and result trees must not contain symlinks that could redirect writes elsewhere.
bool is_reparse(const fs::path& p) {
    std::error_code ec;
    return fs::is_symlink(fs::symlink_status(p, ec));
}
bool inside(const fs::path& file, const fs::path& directory) {
    auto relative = fs::relative(file, directory);
    return !relative.empty() && !relative.is_absolute() && *relative.begin() != "..";
}
void work_directory(const fs::path& root, const fs::path& relative) {
    require(!relative.is_absolute() && !relative.has_root_name(), "Invalid internal work path");
    require(!is_reparse(root), "Work root is a reparse point");
    auto path = root;
    for (const auto& part : relative) {
        require(part != ".." && part != ".", "Invalid internal directory component");
        path /= part;
        fs::create_directory(path);
        require(fs::is_directory(path) && !is_reparse(path),
                "Work subdirectory is not a regular directory: " + utf8(path));
    }
}
void regular_output(const fs::path& root, const fs::path& file) {
    require(fs::is_regular_file(file) && fs::file_size(file) > 0, "Missing/empty output: " + utf8(file));
    auto relative = fs::relative(file, root);
    require(inside(file, root), "Output escaped its stage directory");
    auto p = root;
    require(!is_reparse(p), "Result root is a reparse point");
    for (const auto& component : relative) {
        p /= component;
        require(!is_reparse(p), "Reparse point in result path");
    }
}
std::string dollars(const std::string& s) {
    std::string out;
    for (char c : s) {
        require(c != '\r' && c != '\n' && c != '\0', "Invalid Ninja command");
        if (c == '$') out += '$';
        out += c;
    }
    return out;
}
// Ninja runs commands through /bin/sh -c: single-quote the path, then escape '$' for Ninja.
std::string command_argument(const fs::path& p) {
    std::string quoted = "'";
    for (char c : utf8(p)) {
        if (c == '\'')
            quoted += "'\\''";
        else
            quoted += c;
    }
    quoted += "'";
    return dollars(quoted);
}
int64_t now_ms() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch())
        .count();
}
fs::path source_path(const json& value, const fs::path& base) {
    auto p = from_utf8(text(value));
    return fs::weakly_canonical(p.is_absolute() ? p : base / p);
}
struct Loaded {
    json config;
    fs::path source, root;
    FileLock lock;
};
Loaded load(const fs::path& config_path) {
    Loaded loaded;
    loaded.source = fs::canonical(config_path);
    loaded.config = json::parse(read_text(loaded.source));
    if (loaded.config.contains("workflow_type"))
        loaded.config = loaded.config["workflow_type"] == "reads"
                            ? expand_reads(loaded.config, loaded.source.parent_path())
                            : expand_genotypes(loaded.config, loaded.source.parent_path());
    auto& c = loaded.config;
    keys(c, {"schema_version", "work_dir", "resources", "inputs", "tools", "reference", "tasks"});
    require(number(c, "schema_version", 0, 1, 1) == 1, "schema_version must be 1");
    require(c.contains("work_dir"), "work_dir is required");
    loaded.root = source_path(c["work_dir"], loaded.source.parent_path());
    require(!inside(loaded.source, loaded.root), "Configuration cannot reside in its work directory");
    fs::create_directories(loaded.root);
    require(!is_reparse(loaded.root), "Work directory cannot be a reparse point");
    loaded.lock = exclusive_lock(loaded.root / ".workflow.lock");
    auto marker = loaded.root / "workflow-owner.json";
    if (fs::exists(marker)) {
        auto owner = json::parse(read_text(marker));
        require(owner.value("application", "") == "PopGenA" && owner.value("config", "") == utf8(loaded.source),
                "Work directory belongs to another project/configuration");
    } else {
        for (const auto& e : fs::directory_iterator(loaded.root))
            require(e.path().filename() == ".workflow.lock", "Refusing to adopt a nonempty work directory");
        atomic_text(marker,
                    json{{"application", "PopGenA"}, {"schema_version", 1}, {"config", utf8(loaded.source)}}.dump(2) +
                        "\n");
    }
    return loaded;
}
json completion(const fs::path& root, const std::string& id) {
    auto file = root / "state" / from_utf8(id + ".json");
    require(!is_reparse(file), "Completion record is a reparse point");
    return json::parse(read_text(file));
}
bool matches_outputs(const json& record, bool full) {
    try {
        require(record.at("status") == "complete", "Incomplete task");
        auto root = from_utf8(record.at("result_dir").get<std::string>());
        for (const auto& [name, saved] : record.at("outputs").items()) {
            auto file = root / relative_output(name);
            regular_output(root, file);
            auto current = file_identity(file, full);
            require(current.at("size") == saved.at("size") && current.at("mtime") == saved.at("mtime"),
                    "Output changed");
            if (current.contains("sha256"))
                require(current.at("sha256") == saved.at("sha256"), "Output checksum changed");
        }
        return !record.at("outputs").empty();
    } catch (const std::exception&) {
        return false;
    }
}
bool valid_completion(const fs::path& root, const std::string& id, const json& record, const json& spec,
                      const std::string& hash, bool full) {
    try {
        require(record.at("application") == "PopGenA" && record.at("schema_version") == 1 && record.at("task") == id,
                "Invalid completion record");
        require(record.at("spec_sha256") == hash, "Stale task specification");
        auto attempt = record.at("attempt").get<std::string>();
        require(std::regex_match(attempt, std::regex("[0-9a-f]{32}")), "Invalid attempt identity");
        auto expected = root / "results" / from_utf8(id) / from_utf8(attempt);
        require(from_utf8(record.at("result_dir")) == expected, "Result directory does not belong to this task");
        require(!is_reparse(root / "results" / from_utf8(id)), "Task result parent is a reparse point");
        require(record.at("outputs").size() == spec.at("task").at("outputs").size(), "Incomplete output inventory");
        for (const auto& output : spec.at("task").at("outputs"))
            require(record.at("outputs").contains(output.get<std::string>()), "Missing output in completion inventory");
        require(record.at("dependencies").size() == spec.at("dependencies").size(), "Invalid dependency inventory");
        for (const auto& [name, signature] : spec.at("dependencies").items()) {
            auto dep = completion(root, name);
            require(dep.at("spec_sha256") == signature && record.at("dependencies").at(name) == dep.at("attempt"),
                    "Dependency generation changed");
        }
        return matches_outputs(record, full);
    } catch (const std::exception&) {
        return false;
    }
}
json prepare(Loaded& loaded, bool verify) {
    const auto& c = loaded.config;
    auto base = loaded.source.parent_path(), root = loaded.root;
    auto resources = c.value("resources", json::object());
    keys(resources, {"threads", "memory_mb", "light_jobs"});
    int threads = number(resources, "threads", 8, 1, 8), memory = number(resources, "memory_mb", 10240, 128, 12288),
        light_jobs = number(resources, "light_jobs", 1, 1, 4);
    resources = {{"threads", threads}, {"memory_mb", memory}, {"light_jobs", light_jobs}};
    json inputs = json::object();
    require(c.contains("inputs") && c["inputs"].is_object(), "inputs must be an object");
    for (const auto& [name, value] : c["inputs"].items()) {
        identifier(name);
        auto file = source_path(value, base);
        require(!inside(file, root), "Source inputs cannot be in the workflow work directory");
        inputs[name] = file_identity(file, verify);
    }
    if (c.contains("reference")) require(inputs.contains(text(c["reference"])), "reference must name a declared input");
    json tools = json::object();
    auto tool_config = c.value("tools", json::object());
    require(tool_config.is_object(), "tools must be an object");
    for (const auto& [name, t] : tool_config.items()) {
        identifier(name);
        keys(t, {"path", "version_args"});
        require(t.contains("path"), "Tool path is required");
        auto path = resolve_executable(text(t["path"]), base);
        auto version_args = t.value("version_args", json::array({"--version"}));
        require(version_args.is_array() && !version_args.empty(), "version_args must be a nonempty array");
        for (const auto& a : version_args) text(a);
        tools[name] = {{"identity", file_identity(path, true)}, {"version_args", version_args}};
    }
    require(c.contains("tasks") && c["tasks"].is_array() && !c["tasks"].empty(), "tasks must be a nonempty array");
    require(c["tasks"].size() <= 1000, "At most 1000 tasks are supported");
    std::map<std::string, json> tasks;
    int heavy_threads = 0, heavy_memory = 0, light_threads = 0, light_memory = 0, light_count = 0;
    for (const auto& raw : c["tasks"]) {
        keys(raw, {"id", "kind", "depends_on", "pool", "memory_mb", "timeout_seconds", "commands", "outputs", "stdout",
                   "input", "samples", "hts_threads", "min_dp", "min_gq"});
        auto id = text(raw.at("id"));
        identifier(id);
        require(!tasks.contains(id), "Duplicate task ID: " + id);
        auto kind = text(raw.at("kind"));
        require(kind == "stats" || kind == "command", "Task kind must be stats or command");
        auto dependencies = raw.value("depends_on", json::array());
        require(dependencies.is_array(), "depends_on must be an array");
        std::set<std::string> unique;
        for (const auto& dep : dependencies) {
            auto d = text(dep);
            identifier(d);
            require(d != id && unique.insert(d).second, "Invalid/duplicate task dependency");
        }
        json task = raw;
        task["depends_on"] = dependencies;
        task["pool"] = raw.value("pool", "heavy");
        require(task["pool"] == "heavy" || task["pool"] == "light", "Unknown task pool");
        int task_memory = number(raw, "memory_mb", 1024, 64, memory),
            timeout = number(raw, "timeout_seconds", 3600, 1, 604800), task_threads = 0;
        task["memory_mb"] = task_memory;
        task["timeout_seconds"] = timeout;
        if (kind == "stats") {
            require(raw.contains("input"), "Statistics task requires input");
            text(raw["input"]);
            require(!raw.contains("commands") && !raw.contains("outputs") && !raw.contains("stdout"),
                    "Stats tasks have fixed commands and outputs");
            int hts = number(raw, "hts_threads", 1, 1, 6);
            task["hts_threads"] = hts;
            task_threads = hts + 2;
            task["min_dp"] = number(raw, "min_dp", 0, 0, 1000000000);
            task["min_gq"] = number(raw, "min_gq", 0, 0, 1000000000);
            task["outputs"] = stats_outputs;
        } else {
            for (const auto* field : {"input", "samples", "hts_threads", "min_dp", "min_gq"})
                require(!raw.contains(field), "Command task contains stats-only fields");
            require(raw.contains("commands") && raw["commands"].is_array() && !raw["commands"].empty() &&
                        raw["commands"].size() <= 16,
                    "commands must contain 1..16 processes");
            for (auto& cmd : task["commands"]) {
                keys(cmd, {"argv", "threads"});
                require(cmd.contains("argv") && cmd["argv"].is_array() && !cmd["argv"].empty(),
                        "argv must be a nonempty array");
                for (const auto& a : cmd["argv"]) text(a);
                require(tools.contains(text(cmd["argv"][0])), "First argv item must name a configured tool");
                int count = number(cmd, "threads", 1, 1, threads);
                cmd["threads"] = count;
                task_threads += count;
            }
            require(raw.contains("outputs") && raw["outputs"].is_array() && !raw["outputs"].empty(),
                    "Command task requires declared outputs");
        }
        std::set<std::string> outputs;
        for (const auto& name : task["outputs"]) {
            auto s = text(name);
            relative_output(s);
            require(outputs.insert(s).second, "Duplicate output filename");
        }
        if (task.contains("stdout")) {
            auto s = text(task["stdout"]);
            require(std::find(task["outputs"].begin(), task["outputs"].end(), s) != task["outputs"].end(),
                    "stdout must name a declared output");
        }
        task["reserved_threads"] = task_threads;
        if (task["pool"] == "heavy") {
            heavy_threads = std::max(heavy_threads, task_threads);
            heavy_memory = std::max(heavy_memory, task_memory);
        } else {
            ++light_count;
            light_threads = std::max(light_threads, task_threads);
            light_memory = std::max(light_memory, task_memory);
        }
        tasks.emplace(id, std::move(task));
    }
    int slots = std::min(light_jobs, light_count);
    require(heavy_threads + slots * light_threads <= threads,
            "Concurrent pool thread reservations exceed workflow budget");
    require(heavy_memory + slots * light_memory <= memory,
            "Concurrent pool memory reservations exceed workflow budget");
    std::vector<std::string> order;
    std::map<std::string, int> visited;
    std::function<void(const std::string&)> visit = [&](const std::string& id) {
        require(tasks.contains(id), "Unknown dependency: " + id);
        require(visited[id] != 1, "Workflow dependency cycle");
        if (visited[id] == 2) return;
        visited[id] = 1;
        for (const auto& d : tasks.at(id)["depends_on"]) visit(d.get<std::string>());
        visited[id] = 2;
        order.push_back(id);
    };
    for (const auto& [id, t] : tasks) {
        (void)t;
        visit(id);
    }
    // Validate references before publishing any task specifications or launching processes.
    static const std::regex token("\\{(input|task):([a-z][a-z0-9_-]*)\\}");
    for (const auto& [id, t] : tasks) {
        std::vector<std::string> strings;
        if (t["kind"] == "stats") {
            strings.push_back(text(t["input"]));
            if (t.contains("samples")) strings.push_back(text(t["samples"]));
            for (const auto& source : strings) {
                std::smatch match;
                if (std::regex_match(source, match, std::regex("\\{input:([a-z][a-z0-9_-]*)\\}"))) continue;
                require(std::regex_match(source, match, std::regex("\\{task:([a-z][a-z0-9_-]*)\\}/(.+)")),
                        "Stats inputs must reference a declared input or upstream output");
                auto producer = match[1].str(), name = match[2].str();
                relative_output(name);
                require(tasks.contains(producer), "Unknown upstream task");
                const auto& outputs = tasks.at(producer)["outputs"];
                require(std::find(outputs.begin(), outputs.end(), name) != outputs.end(),
                        "Stats input is not a declared upstream output");
            }
        } else
            for (const auto& cmd : t["commands"])
                for (size_t i = 1; i < cmd["argv"].size(); ++i) strings.push_back(text(cmd["argv"][i]));
        for (auto s : strings) {
            for (auto it = std::sregex_iterator(s.begin(), s.end(), token); it != std::sregex_iterator(); ++it) {
                auto type = (*it)[1].str(), name = (*it)[2].str();
                if (type == "input")
                    require(inputs.contains(name), "Unknown input reference: " + name);
                else
                    require(std::find(t["depends_on"].begin(), t["depends_on"].end(), name) != t["depends_on"].end(),
                            "Task reference lacks direct dependency: " + id + " -> " + name);
            }
            s = std::regex_replace(s, token, "");
            size_t pos = 0;
            while ((pos = s.find("{out}", pos)) != std::string::npos) s.erase(pos, 5);
            require(s.find_first_of("{}") == std::string::npos, "Unknown workflow placeholder");
        }
    }
    auto self = file_identity(executable_path(), true);
    auto ninja = resolve_executable("ninja", base);
    auto ninja_id = file_identity(ninja, true);
    for (const auto* dir : {"tasks", "state", "attempts", "results", "logs"}) work_directory(root, dir);
    std::string graph =
        "ninja_required_version = 1.10\npool heavy\n  depth = 1\npool light\n  depth = " + std::to_string(light_jobs) +
        "\nrule task\n  command = " + command_argument(executable_path()) +
        " step --task $task_file\n  description = TASK $task_id\n  restat = 1\n";
    json task_list = json::array();
    for (const auto& id : order) {
        auto task_file = root / "tasks" / from_utf8(id + ".json");
        json dependencies = json::object();
        for (const auto& dep : tasks.at(id)["depends_on"]) {
            auto d = dep.get<std::string>();
            dependencies[d] = sha256(root / "tasks" / from_utf8(d + ".json"));
        }
        json spec = {{"application", "PopGenA"},
                     {"schema_version", 1},
                     {"work_dir", utf8(root)},
                     {"config", utf8(loaded.source)},
                     {"task", tasks.at(id)},
                     {"inputs", inputs},
                     {"tools", tools},
                     {"executor", self},
                     {"ninja", ninja_id},
                     {"dependencies", dependencies},
                     {"reference", c.value("reference", json(nullptr))}};
        atomic_text(task_file, spec.dump(2) + "\n");
        graph += "build state/" + id + ".json: task tasks/" + id + ".json";
        for (const auto& [dep, hash] : dependencies.items()) {
            (void)hash;
            graph += " state/" + dep + ".json";
        }
        graph += "\n  task_file = " + command_argument(task_file) + "\n  task_id = " + id +
                 "\n  pool = " + tasks.at(id)["pool"].get<std::string>() + "\n";
        task_list.push_back({{"id", id},
                             {"kind", tasks.at(id)["kind"]},
                             {"spec_file", utf8(task_file)},
                             {"outputs", tasks.at(id)["outputs"]},
                             {"pool", tasks.at(id)["pool"]},
                             {"reserved_threads", tasks.at(id)["reserved_threads"]},
                             {"memory_mb", tasks.at(id)["memory_mb"]},
                             {"depends_on", tasks.at(id)["depends_on"]},
                             {"spec_sha256", sha256(task_file)}});
    }
    graph += "build all: phony";
    for (const auto& id : order) graph += " state/" + id + ".json";
    graph += "\ndefault all\n";
    atomic_text(root / "workflow.ninja", graph);
    json report = {{"application", "PopGenA"},
                   {"schema_version", 1},
                   {"config", utf8(loaded.source)},
                   {"work_dir", utf8(root)},
                   {"resources", resources},
                   {"reserved_threads", heavy_threads + slots * light_threads},
                   {"reserved_memory_mb", heavy_memory + slots * light_memory},
                   {"tasks", task_list},
                   {"ninja", utf8(ninja)},
                   {"input_verification", verify ? "full" : "sha256 <=16MiB, size/mtime for larger files"}};
    atomic_text(root / "plan.json", report.dump(2) + "\n");
    return report;
}
void check_identity(const json& expected) {
    auto current = file_identity(from_utf8(expected.at("path").get<std::string>()), expected.contains("sha256"));
    require(current == expected, "Input/tool changed since planning: " + expected.at("path").get<std::string>());
}
std::string substitute(std::string value, const json& spec, const fs::path& stage, const json& dependencies) {
    auto replace = [&](const std::string& token, const std::string& path) {
        size_t pos = 0;
        while ((pos = value.find(token, pos)) != std::string::npos) {
            value.replace(pos, token.size(), path);
            pos += path.size();
        }
    };
    replace("{out}", utf8(stage));
    for (const auto& [name, input] : spec["inputs"].items())
        replace("{input:" + name + "}", input["path"].get<std::string>());
    for (const auto& [name, dep] : dependencies.items())
        replace("{task:" + name + "}", dep["result_dir"].get<std::string>());
    return value;
}
}
json plan_workflow(const fs::path& config, bool verify) {
    auto loaded = load(config);
    return prepare(loaded, verify);
}
json run_workflow(const fs::path& config, bool verify) {
    auto loaded = load(config);
    auto report = prepare(loaded, verify);
    auto root = loaded.root;
    std::set<std::string> invalid;
    int reused = 0;
    for (const auto& task : report["tasks"]) {
        auto id = task["id"].get<std::string>();
        bool valid = true;
        for (const auto& dep : task["depends_on"])
            if (invalid.contains(dep.get<std::string>())) valid = false;
        try {
            auto saved = completion(root, id);
            auto spec = json::parse(read_text(root / "tasks" / from_utf8(id + ".json")));
            valid = valid && valid_completion(root, id, saved, spec, task.at("spec_sha256").get<std::string>(), verify);
        } catch (const std::exception&) {
            valid = false;
        }
        if (!valid) {
            invalid.insert(id);
            std::error_code ec;
            fs::remove(root / "state" / from_utf8(id + ".json"), ec);
            require(!ec, "Cannot invalidate task completion");
        } else
            ++reused;
    }
    std::cerr << "Workflow: " << invalid.size() << " task(s) to execute, " << reused
              << " reusable. Logs: " << utf8(root / "logs") << '\n';
    ProcessOptions options;
    options.cwd = root;
    options.stdout_file = root / "logs" / "ninja.stdout.log";
    options.stderr_file = root / "logs" / "ninja.stderr.log";
    Command command{{report["ninja"].get<std::string>(), "-f", "workflow.ninja", "-j",
                     std::to_string(1 + report["resources"]["light_jobs"].get<int>()), "-k", "1"},
                    1};
    auto result = run_pipeline({command}, options);
    json run = {{"status", result.success() ? "complete" : "failed"},
                {"process", result.record()},
                {"reused_tasks", reused},
                {"scheduled_tasks", invalid.size()},
                {"work_dir", utf8(root)}};
    atomic_text(root / "last-run.json", run.dump(2) + "\n");
    if (!result.success())
        throw std::runtime_error("Workflow failed; see " + utf8(root / "logs" / "ninja.stdout.log") +
                                 " and task attempt logs");
    return run;
}
json execute_task(const fs::path& task_path) {
    auto file = fs::canonical(task_path);
    auto spec = json::parse(read_text(file));
    require(spec.at("application") == "PopGenA" && spec.at("schema_version") == 1,
            "Invalid internal task specification");
    auto root = from_utf8(spec.at("work_dir").get<std::string>());
    auto task = spec.at("task");
    auto id = task.at("id").get<std::string>();
    identifier(id);
    for (const auto* dir : {"tasks", "state", "attempts", "results"}) work_directory(root, dir);
    require(file == fs::canonical(root / "tasks" / from_utf8(id + ".json")),
            "Task specification is outside its workflow");
    auto lock = exclusive_lock(root / "state" / from_utf8(id + ".lock"));
    auto spec_hash = sha256(file);
    for (const auto& input : spec["inputs"].items()) check_identity(input.value());
    check_identity(spec["executor"]);
    json dependencies = json::object();
    for (const auto& [name, hash] : spec["dependencies"].items()) {
        auto dep = completion(root, name);
        auto dep_spec = json::parse(read_text(root / "tasks" / from_utf8(name + ".json")));
        require(valid_completion(root, name, dep, dep_spec, hash.get<std::string>(), false),
                "Dependency is incomplete or invalid: " + name);
        dependencies[name] = dep;
    }
    std::string attempt_id = unique_id();
    auto attempt = root / "attempts" / from_utf8(id) / from_utf8(attempt_id), stage = attempt / "result";
    work_directory(root, fs::path("attempts") / from_utf8(id) / from_utf8(attempt_id));
    json record = {{"application", "PopGenA"}, {"schema_version", 1},          {"task", id},
                   {"attempt", attempt_id},    {"status", "running"},          {"started_unix_ms", now_ms()},
                   {"spec_sha256", spec_hash}, {"inputs", spec["inputs"]},     {"reference", spec["reference"]},
                   {"tools", spec["tools"]},   {"executor", spec["executor"]}, {"dependencies", json::object()}};
    for (const auto& [name, dep] : dependencies.items()) record["dependencies"][name] = dep["attempt"];
    atomic_text(attempt / "attempt.json", record.dump(2) + "\n");
    // Invalidate a prior completion even when this internal step is invoked directly.
    fs::remove(root / "state" / from_utf8(id + ".json"));
    try {
        std::vector<Command> commands;
        if (task["kind"] == "stats") {
            Command cmd;
            cmd.threads = task["reserved_threads"].get<int>();
            cmd.argv = {utf8(executable_path()),
                        "stats",
                        "--input",
                        substitute(task.at("input"), spec, stage, dependencies),
                        "--out",
                        utf8(stage),
                        "--threads",
                        std::to_string(task["hts_threads"].get<int>()),
                        "--min-dp",
                        std::to_string(task["min_dp"].get<int>()),
                        "--min-gq",
                        std::to_string(task["min_gq"].get<int>())};
            if (task.contains("samples")) {
                cmd.argv.push_back("--samples");
                cmd.argv.push_back(substitute(task["samples"], spec, stage, dependencies));
            }
            commands.push_back(std::move(cmd));
            record["tool_versions"] = {{"PopGenA", version}};
        } else {
            fs::create_directory(stage);
            std::set<std::string> used;
            for (const auto& definition : task["commands"]) {
                auto alias = definition["argv"][0].get<std::string>();
                const auto& tool = spec["tools"][alias];
                check_identity(tool["identity"]);
                if (used.insert(alias).second) {
                    Command probe{{tool["identity"]["path"].get<std::string>()}, 1};
                    for (const auto& arg : tool["version_args"]) probe.argv.push_back(arg.get<std::string>());
                    ProcessOptions opts{attempt, attempt / from_utf8(alias + ".version.stdout.log"),
                                        attempt / from_utf8(alias + ".version.stderr.log"), 10000, nullptr};
                    auto result = run_pipeline({probe}, opts);
                    require(result.success(), "Tool version probe failed: " + alias);
                    require(fs::file_size(opts.stdout_file) <= 1024 * 1024 &&
                                fs::file_size(opts.stderr_file) <= 1024 * 1024,
                            "Tool version output too large");
                    record["tool_versions"][alias] = {{"stdout", read_text(opts.stdout_file)},
                                                      {"stderr", read_text(opts.stderr_file)}};
                }
                Command cmd;
                cmd.threads = definition["threads"].get<int>();
                cmd.argv.push_back(tool["identity"]["path"].get<std::string>());
                for (size_t i = 1; i < definition["argv"].size(); ++i)
                    cmd.argv.push_back(substitute(definition["argv"][i], spec, stage, dependencies));
                commands.push_back(std::move(cmd));
            }
            for (const auto& name : task["outputs"])
                fs::create_directories((stage / relative_output(name.get<std::string>())).parent_path());
        }
        record["commands"] = json::array();
        for (const auto& cmd : commands) record["commands"].push_back({{"argv", cmd.argv}, {"threads", cmd.threads}});
        atomic_text(attempt / "attempt.json", record.dump(2) + "\n");
        ProcessOptions opts;
        opts.cwd = attempt;
        opts.stdout_file = task.contains("stdout") ? stage / relative_output(task["stdout"].get<std::string>())
                                                   : attempt / "stdout.log";
        opts.stderr_file = attempt / "stderr.log";
        opts.timeout_ms = task["timeout_seconds"].get<uint64_t>() * 1000;
        auto result = run_pipeline(commands, opts);
        record["process"] = result.record();
        require(result.success(), "Pipeline failed, timed out, or was cancelled");
        for (const auto& input : spec["inputs"].items()) check_identity(input.value());
        require(sha256(file) == spec_hash, "Task definition changed during execution");
        for (const auto& name : task["outputs"])
            regular_output(stage, stage / relative_output(name.get<std::string>()));
        auto published = root / "results" / from_utf8(id) / from_utf8(attempt_id);
        work_directory(root, fs::path("results") / from_utf8(id));
        require(inside(stage, root) && inside(published, root), "Publication path escaped the workflow root");
        fs::rename(stage, published);
        record["result_dir"] = utf8(published);
        record["outputs"] = json::object();
        for (const auto& name : task["outputs"])
            record["outputs"][name.get<std::string>()] =
                file_identity(published / relative_output(name.get<std::string>()), true);
        record["status"] = "complete";
        record["finished_unix_ms"] = now_ms();
        atomic_text(attempt / "attempt.json", record.dump(2) + "\n");
        atomic_text(root / "state" / from_utf8(id + ".json"), record.dump(2) + "\n");
        return {{"task", id}, {"status", "complete"}, {"result_dir", utf8(published)}};
    } catch (const std::exception& error) {
        record["status"] = "failed";
        record["error"] = error.what();
        record["finished_unix_ms"] = now_ms();
        atomic_text(attempt / "attempt.json", record.dump(2) + "\n");
        throw;
    }
}
}
