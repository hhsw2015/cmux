"""
team_schema — JSON contract between an LLM/agent and the team runtime.

Why this exists
---------------
Letting an LLM emit raw Python orchestration scripts is slow (every run
costs prompt tokens) and brittle (a stray import breaks the run). This
module pins down a JSON shape the LLM produces ONCE per goal:

    LLM goal-decomposition  ->  plan.json  ->  Team.run()  ->  cmux RPC

The orchestrator (`Team`) takes care of every dynamic concern:

  - cmux top-tab / panel allocation (per-task panel, dependency-grouped
    tabs, dynamic split layout)
  - $inputs.X.outputs[N] interpolation between tasks
  - prompt-spill to context_file when a prompt blows past N bytes
  - auto-close vs keep-open per task (close_on_done policy)
  - DAG topological scheduling with max_concurrency
  - failure propagation (abort / isolate / continue)
  - artifact assertions

The LLM never writes a scheduling loop.

Schema (version 1)
------------------
::

    {
      "version": 1,                          # required, must equal 1
      "name": "csv-pipeline",                # plan name; shown as the
                                             # team's tab-group title
      "workspace": "/abs/path",              # cwd for every task; required
      "max_concurrency": 4,                  # int 1..8; default 3
      "layout": "auto",                      # "auto"|"main-vertical"|
                                             # "main-horizontal"|
                                             # "even-horizontal"|
                                             # "even-vertical"|"tiled"
      "main_fraction": 0.6,                  # 0.2..0.8; for main-* layouts
      "spill_prompt_threshold_bytes": 4000,  # auto-spill prompts > N bytes
                                             # to a context file
      "on_failure": "abort",                 # "abort"|"isolate"|"continue"
      "timeout_ms": 600000,                  # whole-plan budget; default
                                             # 10min
      "tasks": [
        {
          "id": "scrape",                    # ^[A-Za-z0-9_.:-]{1,32}$
          "prompt": "...",                   # what the agent should do.
                                             # may include $inputs.X.outputs[N]
                                             # tokens which are resolved
                                             # at spawn time
          "needs": [],                       # DAG predecessors by id
          "peers": [],                       # for `peers` semantics
                                             # (informational; not deps)
          "role": "worker",                  # "worker"|"main"|"coordinator"
                                             # |"lead". influences layout
                                             # picking when layout=auto
          "agent": "claude",                 # "claude"|"codex"|"aider"
          "outputs": ["/abs/path/out.json"], # paths predecessors can
                                             # reference via
                                             # $inputs.this_id.outputs[N]
          "expect_artifacts": [],            # files Team.run() asserts
                                             # exist on done; missing =>
                                             # task marked failed
          "close_on_done": "always",         # "always"|"never"|"auto"
          "context_file": null,              # absolute path to a file the
                                             # agent should Read instead
                                             # of receiving inline.
                                             # null => orchestrator may
                                             # auto-spill if prompt is
                                             # too large.
          "panel_direction": "auto",         # "auto"|"right"|"down"
          "timeout_ms": 600000,              # per-task budget
          "extra_env": {}                    # str -> str env overrides
        }
      ]
    }

Conventions
-----------
- Every path is absolute. The orchestrator does not do CWD resolution.
- `$inputs.<task_id>.outputs[<index>]` substitutes the path at spawn
  time. The runtime resolves these AGAINST the predecessor's `outputs`
  list (declared on its task definition), NOT against artifacts the
  agent happens to write. This keeps the wiring explicit.
- A task with no `needs` is a "source"; one with no successor is a
  "sink". sinks do not need expect_artifacts but it's recommended.
- on_failure semantics:
    * abort     - first failure cancels still-pending tasks.
    * isolate   - failed task's descendants get marked `skipped`; the
                  rest of the DAG continues.
    * continue  - all tasks attempt to run regardless of upstream
                  failures. Risky; only use for diagnostic batches.

Validation errors carry a JSON pointer-ish path so the LLM can fix
its own emit:

    PlanValidationError: tasks[2].needs[0]: references unknown task 'fetch_v2'
"""

from __future__ import annotations

import json
import os
import re
from typing import Any, Dict, List, Mapping, Optional, Tuple

from .team import Plan, Task

SCHEMA_VERSION = 1

_LAYOUT_VALUES = (
    "auto",
    "main-vertical",
    "main-horizontal",
    "even-horizontal",
    "even-vertical",
    "tiled",
)
_ON_FAILURE_VALUES = ("abort", "isolate", "continue")
_PANEL_DIRECTION_VALUES = ("auto", "right", "down")
_CLOSE_ON_DONE_VALUES = ("always", "never", "auto")
_AGENT_VALUES = ("claude", "codex", "aider")
_ROLE_VALUES = ("worker", "main", "coordinator", "lead")
_TASK_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,32}$")


class PlanValidationError(ValueError):
    """Raised when plan.json doesn't match the schema. The first arg is
    a path-prefixed message; the second is the offending value (when
    available)."""

    def __init__(self, path: str, message: str, value: Any = None) -> None:
        self.path = path
        self.message = message
        self.value = value
        super().__init__(f"{path}: {message}")


def load_plan(source: str) -> "ResolvedPlan":
    """Parse + validate plan.json (file path OR raw JSON text). Returns
    a ResolvedPlan that wraps the runtime Plan plus extra metadata
    (timeout_ms, expect_artifacts, agent kind per task) the runtime
    needs."""
    if source.startswith("{"):
        text = source
        origin = "<inline>"
    else:
        with open(source, "r", encoding="utf-8") as f:
            text = f.read()
        origin = source
    try:
        data = json.loads(text)
    except json.JSONDecodeError as e:
        raise PlanValidationError(
            "$",
            f"plan source {origin!r} is not valid JSON: {e.msg} at line {e.lineno}",
        ) from e
    if not isinstance(data, dict):
        raise PlanValidationError("$", "plan must be a JSON object")
    return _resolve(data)


def dump_schema_doc() -> str:
    """Returns the human-readable schema doc string. Useful for sub-agent
    prompts: include this so the agent knows exactly what to emit."""
    return __doc__ or ""


# ---------------- internal validation ----------------


class ResolvedPlan:
    """Runtime-ready Plan + per-task metadata that team.Plan/Task don't
    carry directly. Kept separate so we don't silently change `Task`'s
    on-the-wire shape."""

    def __init__(
        self,
        plan: Plan,
        timeout_ms: int,
        expect_artifacts: Mapping[str, List[str]],
        agent_for_task: Mapping[str, str],
    ) -> None:
        self.plan = plan
        self.timeout_ms = timeout_ms
        self.expect_artifacts = dict(expect_artifacts)
        self.agent_for_task = dict(agent_for_task)


def _resolve(data: Dict[str, Any]) -> ResolvedPlan:
    version = data.get("version")
    if version != SCHEMA_VERSION:
        raise PlanValidationError(
            "$.version",
            f"unsupported version {version!r}; this runtime understands version {SCHEMA_VERSION}",
            value=version,
        )

    workspace = _require_string(data, "workspace", "$")
    if not os.path.isabs(workspace):
        raise PlanValidationError("$.workspace", "must be an absolute path", value=workspace)
    if not os.path.isdir(workspace):
        raise PlanValidationError("$.workspace", f"directory does not exist: {workspace}", value=workspace)

    name = data.get("name", "")
    if not isinstance(name, str):
        raise PlanValidationError("$.name", "must be a string", value=name)

    on_failure = data.get("on_failure", "abort")
    if on_failure not in _ON_FAILURE_VALUES:
        raise PlanValidationError(
            "$.on_failure",
            f"must be one of {_ON_FAILURE_VALUES}",
            value=on_failure,
        )

    layout = data.get("layout", "auto")
    if layout not in _LAYOUT_VALUES:
        raise PlanValidationError("$.layout", f"must be one of {_LAYOUT_VALUES}", value=layout)

    main_fraction = data.get("main_fraction", 0.6)
    if not isinstance(main_fraction, (int, float)) or not 0.2 <= float(main_fraction) <= 0.8:
        raise PlanValidationError(
            "$.main_fraction",
            "must be a number in [0.2, 0.8]",
            value=main_fraction,
        )

    max_concurrency = data.get("max_concurrency", 3)
    if not isinstance(max_concurrency, int) or not 1 <= max_concurrency <= 8:
        raise PlanValidationError(
            "$.max_concurrency",
            "must be an integer in [1, 8]",
            value=max_concurrency,
        )

    spill = data.get("spill_prompt_threshold_bytes", 4_000)
    if not isinstance(spill, int) or spill < 256:
        raise PlanValidationError(
            "$.spill_prompt_threshold_bytes",
            "must be an integer >= 256",
            value=spill,
        )

    plan_timeout_ms = data.get("timeout_ms", 600_000)
    if not isinstance(plan_timeout_ms, int) or plan_timeout_ms < 1_000:
        raise PlanValidationError(
            "$.timeout_ms",
            "must be an integer >= 1000 (ms)",
            value=plan_timeout_ms,
        )

    raw_tasks = data.get("tasks")
    if not isinstance(raw_tasks, list) or not raw_tasks:
        raise PlanValidationError("$.tasks", "must be a non-empty array", value=raw_tasks)

    tasks: List[Task] = []
    expect_artifacts: Dict[str, List[str]] = {}
    agent_for_task: Dict[str, str] = {}
    seen_ids: set = set()
    for i, raw in enumerate(raw_tasks):
        path = f"$.tasks[{i}]"
        if not isinstance(raw, dict):
            raise PlanValidationError(path, "must be a JSON object", value=raw)
        task, agent_kind, expect = _resolve_task(raw, path, seen_ids)
        tasks.append(task)
        expect_artifacts[task.id] = expect
        agent_for_task[task.id] = agent_kind
        seen_ids.add(task.id)

    plan = Plan(
        workspace=workspace,
        tasks=tasks,
        name=name,
        on_failure=on_failure,
        spill_prompt_threshold_bytes=spill,
        layout=layout,
        main_fraction=float(main_fraction),
        max_concurrency=max_concurrency,
    )
    # Cross-task reference checks (needs / peers / $inputs).
    _validate_cross_refs(plan)
    return ResolvedPlan(
        plan=plan,
        timeout_ms=plan_timeout_ms,
        expect_artifacts=expect_artifacts,
        agent_for_task=agent_for_task,
    )


def _resolve_task(
    raw: Dict[str, Any], path: str, seen_ids: set
) -> Tuple[Task, str, List[str]]:
    tid = _require_string(raw, "id", path)
    if not _TASK_ID_RE.match(tid):
        raise PlanValidationError(
            f"{path}.id",
            f"must match {_TASK_ID_RE.pattern}",
            value=tid,
        )
    if tid in seen_ids:
        raise PlanValidationError(f"{path}.id", f"duplicate task id {tid!r}", value=tid)

    prompt = _require_string(raw, "prompt", path, allow_empty=False)

    needs = _string_list(raw.get("needs", []), f"{path}.needs")
    peers = _string_list(raw.get("peers", []), f"{path}.peers")
    outputs = _string_list(raw.get("outputs", []), f"{path}.outputs")
    inputs_decl = _string_list(raw.get("inputs", []), f"{path}.inputs")
    expect = _string_list(raw.get("expect_artifacts", []), f"{path}.expect_artifacts")
    for j, p in enumerate(outputs):
        if not os.path.isabs(p):
            raise PlanValidationError(
                f"{path}.outputs[{j}]",
                "must be an absolute path",
                value=p,
            )
    for j, p in enumerate(expect):
        if not os.path.isabs(p):
            raise PlanValidationError(
                f"{path}.expect_artifacts[{j}]",
                "must be an absolute path",
                value=p,
            )

    role = raw.get("role", "worker")
    if role not in _ROLE_VALUES:
        raise PlanValidationError(
            f"{path}.role",
            f"must be one of {_ROLE_VALUES}",
            value=role,
        )

    panel_direction = raw.get("panel_direction", "auto")
    if panel_direction not in _PANEL_DIRECTION_VALUES:
        raise PlanValidationError(
            f"{path}.panel_direction",
            f"must be one of {_PANEL_DIRECTION_VALUES}",
            value=panel_direction,
        )

    close_on_done = raw.get("close_on_done", "always")
    if close_on_done not in _CLOSE_ON_DONE_VALUES:
        raise PlanValidationError(
            f"{path}.close_on_done",
            f"must be one of {_CLOSE_ON_DONE_VALUES}",
            value=close_on_done,
        )

    agent_kind = raw.get("agent", "claude")
    if agent_kind not in _AGENT_VALUES:
        raise PlanValidationError(
            f"{path}.agent",
            f"must be one of {_AGENT_VALUES}",
            value=agent_kind,
        )

    timeout_ms = raw.get("timeout_ms", 600_000)
    if not isinstance(timeout_ms, int) or timeout_ms < 1_000:
        raise PlanValidationError(
            f"{path}.timeout_ms",
            "must be an integer >= 1000 (ms)",
            value=timeout_ms,
        )

    extra_env_raw = raw.get("extra_env", {})
    if not isinstance(extra_env_raw, dict):
        raise PlanValidationError(f"{path}.extra_env", "must be an object", value=extra_env_raw)
    extra_env: Dict[str, str] = {}
    for k, v in extra_env_raw.items():
        if not isinstance(k, str) or not isinstance(v, str):
            raise PlanValidationError(
                f"{path}.extra_env",
                "all keys and values must be strings",
                value={k: v},
            )
        extra_env[k] = v

    context_file_raw = raw.get("context_file")
    if context_file_raw is not None:
        if not isinstance(context_file_raw, str) or not os.path.isabs(context_file_raw):
            raise PlanValidationError(
                f"{path}.context_file",
                "must be null or an absolute path",
                value=context_file_raw,
            )
    context_file = context_file_raw

    # Reject unknown keys early — better than silently dropping them.
    known = {
        "id", "prompt", "needs", "peers", "role", "agent", "outputs", "inputs",
        "expect_artifacts", "close_on_done", "context_file",
        "panel_direction", "timeout_ms", "extra_env",
    }
    unknown = sorted(set(raw.keys()) - known)
    if unknown:
        raise PlanValidationError(
            path,
            f"unknown keys: {unknown}",
            value=unknown,
        )

    task = Task(
        id=tid,
        prompt=prompt,
        needs=needs,
        inputs=inputs_decl,
        outputs=outputs,
        role=role,
        peers=peers,
        timeout_ms=timeout_ms,
        panel_direction=panel_direction,
        extra_env=extra_env,
        close_on_done=close_on_done,
        context_file=context_file,
    )
    return task, agent_kind, expect


def _require_string(d: Dict[str, Any], key: str, path: str, *, allow_empty: bool = False) -> str:
    if key not in d:
        raise PlanValidationError(path, f"missing required field {key!r}")
    val = d[key]
    if not isinstance(val, str):
        raise PlanValidationError(f"{path}.{key}", "must be a string", value=val)
    if not allow_empty and not val.strip():
        raise PlanValidationError(f"{path}.{key}", "must be non-empty", value=val)
    return val


def _string_list(value: Any, path: str) -> List[str]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise PlanValidationError(path, "must be an array of strings", value=value)
    out: List[str] = []
    for i, v in enumerate(value):
        if not isinstance(v, str):
            raise PlanValidationError(f"{path}[{i}]", "must be a string", value=v)
        out.append(v)
    return out


def _validate_cross_refs(plan: Plan) -> None:
    """Raise PlanValidationError-style errors for needs/peers/$inputs
    that point at unknown ids, plus run cycle detection."""
    id_set = {t.id for t in plan.tasks}
    by_id = {t.id: t for t in plan.tasks}
    for ti, t in enumerate(plan.tasks):
        for ni, n in enumerate(t.needs):
            if n not in id_set:
                raise PlanValidationError(
                    f"$.tasks[{ti}].needs[{ni}]",
                    f"references unknown task {n!r}",
                    value=n,
                )
        for pi, p in enumerate(t.peers):
            if p not in id_set:
                raise PlanValidationError(
                    f"$.tasks[{ti}].peers[{pi}]",
                    f"references unknown task {p!r}",
                    value=p,
                )
        for m in re.finditer(r"\$inputs\.([A-Za-z0-9_.:-]+)\.outputs\[(\d+)\]", t.prompt):
            ref_id, idx_s = m.group(1), m.group(2)
            idx = int(idx_s)
            if ref_id not in id_set:
                raise PlanValidationError(
                    f"$.tasks[{ti}].prompt",
                    f"$inputs.{ref_id}.outputs[{idx}] references unknown task",
                    value=ref_id,
                )
            if ref_id not in t.needs:
                raise PlanValidationError(
                    f"$.tasks[{ti}].prompt",
                    f"$inputs.{ref_id}.outputs[{idx}] requires {ref_id!r} in needs",
                    value=t.needs,
                )
            if idx >= len(by_id[ref_id].outputs):
                raise PlanValidationError(
                    f"$.tasks[{ti}].prompt",
                    f"$inputs.{ref_id}.outputs[{idx}]: predecessor declares only "
                    f"{len(by_id[ref_id].outputs)} outputs",
                    value=idx,
                )

    # Cycle detection (DFS with three colors).
    WHITE, GRAY, BLACK = 0, 1, 2
    color = {tid: WHITE for tid in id_set}
    deps = {t.id: list(t.needs) for t in plan.tasks}

    def visit(node: str, stack: List[str]) -> None:
        if color[node] == GRAY:
            cycle = stack + [node]
            raise PlanValidationError(
                "$.tasks",
                f"cycle: {' -> '.join(cycle)}",
                value=cycle,
            )
        if color[node] == BLACK:
            return
        color[node] = GRAY
        for d in deps[node]:
            visit(d, stack + [node])
        color[node] = BLACK

    for tid in sorted(id_set):
        if color[tid] == WHITE:
            visit(tid, [])
