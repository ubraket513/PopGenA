#pragma once
// Planned, resumable workflows executed through generated Ninja graphs (docs/WORKFLOWS.md).
#include "core/platform.hpp"

namespace pg {
// Validates a configuration and writes plan.json, task specifications and workflow.ninja.
json plan_workflow(const fs::path& config, bool verify = false);
// Plans, invalidates stale completions and executes/resumes the graph.
json run_workflow(const fs::path& config, bool verify = false);
// Internal `popgen step`: executes one generated task specification.
json execute_task(const fs::path& task_file);
}
