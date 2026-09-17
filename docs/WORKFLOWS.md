# Workflow execution

Milestone 3 adds a workflow layer around native executables and the existing statistics command. The example deliberately stops at BCF conversion and statistics; it does not yet perform genotype QC, LD pruning, PCA or raw-read calling.

## Run the offline example

```bash
make plan                                  # validate and write a reviewable plan
make workflow                              # execute or resume the same plan
make workflow                              # verifies prior results and reuses them
```

Both targets accept `CONFIG=path/to/config.json`. The binary equivalents are:

```bash
build/popgen plan --config config/workflow-demo.json
build/popgen run --config config/workflow-demo.json
build/popgen run --config config/workflow-demo.json --verify-inputs
```

Paths in the config are relative to the config file, independent of the current directory. `plan` validates dependencies and resource reservations, identifies input/tool files, and writes `plan.json`, task JSON and `workflow.ninja`. It does not launch tasks, run version probes, install tools, or download data. Small-file hashing and local metadata reads are part of planning.

Use `popgen run` to execute the graph. It regenerates changed specifications and validates completed outputs before asking Ninja to schedule work. Running the generated Ninja file directly bypasses this preflight and is not the supported resume interface. Ninja itself is the vendored build in `.deps/linux/prefix/bin/ninja`.

The bundled example runs two actual bcftools processes connected by a pipe, then launches `popgen stats` on the resulting BCF. Tool versions, argv arrays, exit statuses and input identities are recorded with the attempt. No shell is inserted between pipeline processes.

## Configuration, schema 1

See `config/workflow-demo.json` for a complete example. Top-level fields are:

| Field | Meaning |
|---|---|
| `schema_version` | Must be 1. |
| `work_dir` | Dedicated generated-work directory. A nonempty unowned directory is refused. |
| `resources` | `threads` (default 8, maximum 8), `memory_mb` (default 10240, maximum 12288), `light_jobs` (default 1, maximum 4). |
| `inputs` | Map of input IDs to existing local file paths. Inputs must be outside `work_dir`. |
| `tools` | Map of tool IDs to `path` and optional `version_args` (default `["--version"]`). |
| `reference` | Optional input ID identifying the exact reference file. Its identity is retained in task records. |
| `tasks` | Nonempty task array, at most 1000 tasks. |

Unknown fields, duplicate task IDs, cycles, missing dependencies, invalid placeholders, unsafe output names and over-budget plans are errors. Input/tool/task IDs use lowercase ASCII letters, digits, underscores and hyphens, starting with a letter.

Each task has an `id`, `kind`, optional `depends_on`, `pool` (`heavy` by default or `light`), `memory_mb` (default 1024), and `timeout_seconds` (default 3600, range 1–604800).

For `kind: "stats"`, supply `input`, optional `samples`, `hts_threads` (default 1, maximum 6), `min_dp` and `min_gq`. Inputs must be `{input:name}` or `{task:producer}/declared-output`. Stats outputs are fixed to the five files documented in `STATISTICS.md`; no custom commands or stdout redirection are accepted for this task type.

For `kind: "command"`, supply:

```json
{
  "commands": [
    {"argv": ["tool-id", "arg1", "{input:cohort}"], "threads": 1},
    {"argv": ["other-tool", "--output", "{out}/result.bcf"], "threads": 1}
  ],
  "outputs": ["result.bcf"]
}
```

There may be 1–16 commands per pipeline. The first argv element names a configured tool; the remaining elements are literal arguments with optional placeholders:

- `{input:name}` expands to a declared source file.
- `{task:id}` expands to that dependency's validated result directory. A direct `depends_on` entry is required.
- `{out}` expands to the attempt's temporary result directory.

An optional `stdout` field redirects the last process to a declared output file, useful for tools that write their result to stdout. Otherwise stdout and stderr are captured in attempt logs. Declare every required artifact in `outputs`, including indexes/sidecars. Generic validation requires each declared file to exist, be nonempty, and stay within the result directory without symbolic links. It does not prove that arbitrary command output is a scientifically valid BCF or another file format; tool-specific validation belongs in downstream analysis milestones.

Tool paths containing a slash resolve against the config directory. Bare names resolve to the vendored tools in `.deps/linux/prefix/bin` (next to `build/`) and then to PATH. Only regular executable files are accepted. Version probes run during task execution with a 10-second timeout. A failed probe fails the task. Configuration is trusted executable workflow code, not a sandbox: the runner controls publication and child lifetime, but cannot prevent a tool from writing to other paths explicitly passed in its arguments.

## Resource accounting

All heavy tasks share one Ninja pool of depth one. The light pool has the configured depth. The planner conservatively reserves the largest heavy task plus the maximum simultaneous light tasks, and rejects plans exceeding the CPU or memory budget, even if dependencies might prevent that worst case.

Pipeline CPU reservations are the sum of declared command thread counts. Statistics reserve `hts_threads + 2`, allowing for decompression workers, BGZF I/O and the coordinating thread. Native command flags must agree with their declared thread counts; arbitrary executables can create additional threads, so these reservations are not an OS CPU quota. Each child receives its declared `OMP_NUM_THREADS`, while `OPENBLAS_NUM_THREADS` and `MKL_NUM_THREADS` are fixed to 1. Locale is set to `C`.

`memory_mb` is a planning reservation, not an enforced limit: the planner refuses workflows whose concurrent reservations exceed `resources.memory_mb`, and genotype/read workflows pass matching memory flags to the tools (for example PLINK `--memory`, `samtools sort -m`). Small orchestration processes and filesystem caches add overhead outside the reservation; leave OS headroom.

Each pipeline runs in its own process group. Commands are started with `fork`/`execve`: argv is passed unchanged (no shell), stdin is `/dev/null`, and only stdin/stdout/stderr are inherited (all other descriptors are close-on-exec). An exec failure is reported before any later stage starts. A failed stage, timeout or cancellation sends SIGTERM to the whole group and SIGKILL after five seconds; after a successful pipeline any leftover descendants in the group are killed before outputs are published. Version probes have a 10-second timeout.

## Completion, failure and resume

```text
work_dir/
  workflow-owner.json        associates this directory with its config
  plan.json                  resource/dependency summary
  workflow.ninja             generated execution graph
  tasks/<id>.json            effective task specifications
  state/<id>.json            successful completion records
  attempts/<id>/<attempt>/   command/version logs and attempt.json
  results/<id>/<attempt>/    successfully published output generations
  logs/                     latest Ninja stdout/stderr
  last-run.json              latest workflow execution summary
```

Output generations and attempt logs are retained. A task runs in a fresh attempt directory. All pipeline processes must exit successfully, inputs must still match the plan, and required outputs must pass validation. The result directory is then moved to its final generation location and an atomic completion record is published. No completed result is overwritten in place.

Before a rerun, completion records are checked against the effective task definition, dependency generations, expected output inventory and file identities. Invalid tasks and their dependants lose their completion markers and are rerun; their previous result directories remain for inspection. An unchanged task retains its completion marker and is not relaunched. Configuration changes affecting a downstream task do not require rerunning a valid upstream task. Changes to declared source/tool identities currently conservatively invalidate all task specifications, including tasks that do not directly use that input/tool.

Terminating the runner, even with SIGKILL, terminates Ninja, workers and grandchildren: every command started by a runner (including Ninja) and every `popgen step` requests a parent-death SIGTERM (`PR_SET_PDEATHSIG`), Ninja forwards SIGTERM to its jobs, and each step then terminates its tool process group. SIGINT/SIGTERM/SIGHUP cancel cleanly. The top-level `popgen run` itself does not follow its parent, so it keeps running under `nohup` after the launching shell exits. A hard kill may leave an attempt marked `running`, but it cannot be reused without a complete, valid success record. Restart `popgen run` to recover. Unpublished attempts and orphan result generations are retained; automatic garbage collection is intentionally not implemented. Exclusive locks prevent concurrent coordinators from writing the same work directory and concurrent workers from executing the same task. Locks are `flock` advisory locks released by the kernel when their holder exits, so a crash or power failure does not leave a stale lock.

Small inputs and output checks use SHA256 up to 16 MiB. Larger files use size and last-write time on routine resume, avoiding a full read of multi-terabyte data. Every output receives a full SHA256 at publication. Executables are fully hashed. `--verify-inputs` fully hashes large source files during planning and large prior outputs during resume. Introducing full source verification can change the effective specification and trigger one rebuild. If large file content is changed while preserving both size and timestamp, routine metadata-only checks will not detect it; treat these files as immutable or use full verification. This is an incremental workflow, not a content-addressed cache or a hermetic execution environment.

## Validation

Task process records include wall time, user/system CPU time summed over the
pipeline, the exit status of every stage, and `max_rss_bytes`: the peak resident
set size of the largest single process (including its waited-for descendants),
from `wait4`. It is not the sum across concurrently running pipeline stages. See
[measurements and limits](VALIDATION.md).

`make check` includes real native process and workflow tests: argument passing with Unicode and shell metacharacters, pipe-buffer draining, upstream failure with downstream success, timeout, cancellation, descendant cleanup, plans without execution, reuse, changed config/input/tool identity, missing/corrupt outputs, different caller directories, partial failures, SIGKILL of the runner with descendant cleanup, interrupted-owner recovery, pool scheduling and invalid configurations. Scientific output is compared with the same independent offline goldens used by the standalone statistics command.

Implementation references: [Ninja manual](https://ninja-build.org/manual.html), [prctl(2) PR_SET_PDEATHSIG](https://man7.org/linux/man-pages/man2/prctl.2.html), [flock(2)](https://man7.org/linux/man-pages/man2/flock.2.html) and [wait4(2)](https://man7.org/linux/man-pages/man2/wait4.2.html).
