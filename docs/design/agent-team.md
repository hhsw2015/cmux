# cmux Agent Team Orchestrator — Design

Status: draft
Owner: cmux-terminal-control
Builds on: docs/design/agent-bus.md

## TL;DR

A thin Python orchestrator (`cmux_term.team`) that turns a **task DAG**
into a running multi-agent team. The dispatcher LLM:

1. decomposes a goal into a list of `Task` objects with declared
   inputs / outputs / dependencies,
2. hands the list to `Team.run(plan)`,
3. verifies the final aggregated artifact when `run` returns.

The orchestrator does the rest:
- topological scheduling (spawn an agent the moment its deps clear),
- per-agent panel layout (right / down so the team isn't squashed),
- bus-protocol prompt assembly (each agent told where to read inputs
  and where to publish outputs),
- collecting `done` messages over the bus, dismissing as it goes,
- forwarding upstream artifact paths into downstream prompts,
- propagating cancellation when one task fails (configurable),
- streaming progress events back to the dispatcher.

Built entirely on the bus primitives we already shipped — no new RPCs.

## 1. Data model

### 1.1 `Task`

```python
@dataclass
class Task:
    id: str                           # stable, human-readable: "lint", "build", "test"
    prompt: str                       # what the worker should do, in natural language
    needs: list[str] = []             # task ids this depends on
    inputs: list[str] = []            # extra absolute paths read by this task
    outputs: list[str] = []           # absolute paths the worker MUST produce
    role: str = "worker"              # free-form label for the prompt prelude
    timeout_ms: int = 600_000
    panel_direction: str = "auto"     # "right" | "down" | "auto" (orchestrator picks)
    agent_cls: type = ClaudeAgent     # which CLI; defaults to Claude
    extra_env: dict = {}              # agent's bus identity is auto-injected
```

Constraints:

- `id` matches `^[A-Za-z0-9_.:-]+$`, ≤ 32 chars (becomes the bus
  `from` / `agent_id`, so it must be selector-safe).
- `needs` ids must all be present in the same plan; cycles rejected.
- Each upstream output appears as an inline `inputs:` reference for
  every downstream task (the orchestrator wires this automatically;
  see §2.3).

### 1.2 `Plan`

```python
@dataclass
class Plan:
    workspace: str                    # absolute path; orchestrator cd's there
    tasks: list[Task]
    name: str = ""                    # for logs
    on_failure: Literal["abort", "isolate", "continue"] = "abort"
    max_concurrency: int = 4          # cap parallelism (also bounded by bus capacity)
```

`on_failure`:
- **abort** (default) — first `error` message cancels every still-
  running task, raises.
- **isolate** — the failing task and every transitive downstream is
  marked failed; siblings keep running. Useful when subtree is
  optional.
- **continue** — log only, don't cancel. Tests this through.

### 1.3 `RunResult`

```python
@dataclass
class RunResult:
    outcomes: dict[str, TaskOutcome]  # by task id
    started_at: datetime
    finished_at: datetime
    plan: Plan
```

```python
@dataclass
class TaskOutcome:
    task_id: str
    status: Literal["done", "failed", "skipped", "cancelled"]
    summary: str
    artifacts: list[str]
    error: str | None
    bus_messages: list[AgentBusMessage] # progress + done, in order
    panel_id: str | None
    started_at: datetime | None
    finished_at: datetime | None
```

## 2. Scheduling

### 2.1 Topological wave scheduler

```
ready = tasks whose `needs` are all in done_set
while ready or in_flight:
    while ready and len(in_flight) < max_concurrency:
        spawn next ready task
    msg = bus.wait_any(agents=[t.id for t in in_flight], timeout_ms=...)
    handle(msg)            # done | error | needs_input | progress
    advance done/failed/cancelled sets, recompute ready
```

**Why `wait_any`, not `wait_all`**: we need to react to the first
agent that finishes (or fails / asks a question) so we can:
- release its panel for layout reuse,
- spawn newly-unblocked downstream tasks,
- propagate cancellation early on failure.

`wait_all` would block until everyone finishes, which kills
overlapping new spawns.

### 2.2 Panel layout

Three primitives, picked by the orchestrator from each Task's
`panel_direction` + a stack-tracking heuristic:

- **right** — split off the dispatcher's panel. First worker only.
- **down** — split off the previous worker's panel. Subsequent
  workers stack vertically on the right side.
- **auto** — first goes `right`, rest go `down` (the multi-agent
  demo pattern). The orchestrator does this when no explicit
  direction is given.

Future (out of scope for v1): grid layout via cmux's `layout.set`.

### 2.3 Input wiring

When task **D** needs task **U**'s output:

```python
Task(id="D", needs=["U"], prompt="Use the contents of $inputs.U.outputs[0] to ...")
```

The orchestrator substitutes `$inputs.U.outputs[N]` with the actual
path (read from `U`'s bus `done` message's `artifacts` array) BEFORE
sending the prompt to D. If U produced no artifacts and D references
them, that's an `invalid_plan` error caught at parse time when
possible, runtime otherwise.

### 2.4 Bus protocol per task

Each task's prompt is assembled as:

```
[ROLE PRELUDE]
You are sub-agent {task.id}, role: {task.role}.
This is a coordinated multi-agent run. Workspace: {plan.workspace}.

[INPUTS]
You have these inputs available on disk:
  - <path>  (description from upstream task summary, if any)
  - ...

[TASK]
{task.prompt}

[OUTPUTS]
When done, the following files MUST exist:
  - <output_path_1>
  - ...

[BUS PROTOCOL]
{render_protocol_instructions(agent=task.id, ref=run_token)}
```

`render_protocol_instructions` already exists in `cmux_term.bus`.

## 3. Communication patterns supported

The DAG covers most patterns — but the bus also lets sibling agents
talk peer-to-peer at runtime if they need to. The orchestrator
exposes that via:

```python
Task(id="reviewer", peers=["coder_a","coder_b"], ...)
```

`peers` adds extra `kind=note` permissions to the prompt: the agent
gets told "you may message any of [peers] with kind=note and they'll
receive your message". The orchestrator does NOT mediate these
messages — it just permits them. Useful for pipelines and review
patterns.

Closed list of patterns the orchestrator handles natively in v1:

| Pattern | How it expresses |
|---|---|
| **Fan-out** (1 → N parallel) | N tasks all `needs=[]`, then a final aggregator with `needs=[a,b,...,n]` |
| **Pipeline** (A → B → C) | C `needs=[B]`, B `needs=[A]` |
| **Diamond** (A → {B,C} → D) | D `needs=[B,C]`, B+C both `needs=[A]` |
| **Map-reduce** | Same as fan-out + aggregator |
| **Peer review** | Reviewer task with `peers=[coder]` and `needs=[coder]` |
| **Conditional branch** | Out of scope v1; user resubmits a new plan after seeing the first result |

## 4. Failure modes

| Event | Behavior |
|---|---|
| Agent publishes `error` | Task marked failed. `on_failure` decides cascade. |
| Agent silently exits without publishing | Task hits `timeout_ms`, marked failed. |
| Agent publishes `needs_input` | Orchestrator surfaces the message via a callback (`Plan.on_question`); default `Plan.on_failure='abort'` cancels the run if no callback handles it. v1 doesn't auto-answer. |
| Bus message references a non-existent ref | Logged, ignored. |
| Daemon restart mid-run | All in-flight agents lose their bus subscriptions. Orchestrator's `wait_any` returns the first message it sees post-restart; tasks already done are recoverable from disk. v1: documented limitation, retry-from-scratch is the user's call. |
| Cycle in `needs` graph | Rejected at `Plan(...)` construction with `invalid_plan`. |
| Reference to undefined task in `needs` | Rejected at construction. |

## 5. API shape

```python
from cmux_term import Plan, Task, Team

plan = Plan(
    workspace="/tmp/proj",
    tasks=[
        Task(id="scrape", prompt="Read input.csv, normalize, write normalized.json",
             outputs=["/tmp/proj/normalized.json"]),
        Task(id="stat",  prompt="Read $inputs.scrape.outputs[0] and write stats.json",
             needs=["scrape"], outputs=["/tmp/proj/stats.json"]),
        Task(id="plot",  prompt="Read $inputs.stat.outputs[0] and write plot.png",
             needs=["stat"], outputs=["/tmp/proj/plot.png"]),
        Task(id="report",
             prompt="Use $inputs.stat.outputs[0] and $inputs.plot.outputs[0] to write report.md",
             needs=["stat","plot"], outputs=["/tmp/proj/report.md"]),
    ],
)

team = Team(parent_surface_id=parent.id, max_concurrency=3)
result = team.run(plan, timeout_ms=30 * 60_000)

assert all(o.status == "done" for o in result.outcomes.values())
print(open("/tmp/proj/report.md").read())
```

The dispatcher wrote 4 lines of plan; the orchestrator handled
4 panel splits, 4 prompt syntheses, 4 bus subscriptions, 4 dismissals,
and topo ordering.

## 6. LLM-driven decomposition

The above plan is hand-written. The intended workflow is:

```python
# Step 1: dispatcher LLM thinks about the user's goal and emits Plan JSON
plan_json = llm_decompose(user_goal, context_files, system_prompt=DECOMPOSE_PROMPT)
plan = Plan.from_json(plan_json)

# Step 2: validate (cycles, undefined refs, suspicious prompts)
plan.validate()

# Step 3: run
result = Team(parent_surface_id).run(plan)

# Step 4: dispatcher inspects result, may decide to re-run / extend / accept
```

`DECOMPOSE_PROMPT` is a short system prompt template (we ship one in
`cmux_term/team_prompts.py`) telling the LLM to:
- emit a list of tasks with the JSON schema in §1.1,
- prefer tasks ≤ 5 minutes wall each,
- always declare `outputs` (no agent should write only stdout),
- avoid cycles,
- mark optional subtrees with `on_failure=isolate` semantics
  (currently per-plan, but per-task is a reasonable v2 add).

The LLM-decomposition step is itself just another delegation —
the dispatcher can spawn a `decomposer` Claude that emits the plan
to a file, then `Plan.from_json(open(file).read())`.

## 7. Implementation surface

New file: `skills/cmux-terminal-control/lib/cmux_term/team.py` (~400 LOC).

```python
@dataclass
class Task:    ...
@dataclass
class Plan:
    @classmethod
    def from_json(cls, s: str) -> "Plan": ...
    def validate(self) -> None: ...      # cycles, refs, id syntax
    def topo_order(self) -> list[list[Task]]: ...   # waves

class Team:
    def __init__(self, *, parent_surface_id, max_concurrency=4, on_event=None): ...
    def run(self, plan: Plan, *, timeout_ms=...) -> RunResult: ...
    def cancel(self) -> None: ...
```

Internals:
- `_spawn_task(task)` — choose direction, ClaudeAgent.spawn, register
  `agent_id=task.id` so bus messages route correctly.
- `_assemble_prompt(task, upstream_outcomes)` — substitute
  `$inputs.X.outputs[N]` placeholders, prepend role prelude, append
  bus protocol prose.
- `_handle_message(msg, state)` — switch on `msg.kind`, advance state
  machine, emit progress event.
- `_state` — dict of TaskOutcome by id, plus `in_flight: set[str]`
  and `cancelled: bool`.

Reuses everything that already exists:
- `ClaudeAgent.spawn(...)` — direction param, agent_id propagation.
- `AgentBus.wait_any(agents=...)` — single bus subscription for the
  entire fleet.
- `bus.publish_command(...)` — for prompt assembly.
- `Surface.close()` — when a task's panel is no longer needed.

## 8. Demo

`skills/cmux-terminal-control/lib/team_demo.py`:

> Goal: process a CSV through scrape → stat → (plot, summarize) →
> report. 5 tasks, diamond DAG, 3-deep critical path, 2-way fan-out
> in the middle. Verify final report.md contains all upstream
> contributions.

Should run end-to-end in ≤ 2 minutes wall time.

## 9. Acceptance criteria

- [ ] `Plan.validate()` rejects cycles + undefined `needs` references.
- [ ] `Team.run()` starts every leaf task in parallel up to
      `max_concurrency`, then schedules dependents as deps clear.
- [ ] Each task receives upstream artifact paths inlined in its
      prompt; dispatcher never needs to manually wire inputs.
- [ ] On `done` the orchestrator dismisses the bus message so no
      stale message blocks subsequent waits.
- [ ] On `error` with `on_failure=abort`, in-flight workers receive
      a `cancel` bus message AND `Ctrl+C` in their panel; the run
      raises with `RunResult.outcomes` filled out for both done and
      cancelled tasks.
- [ ] Dispatcher token cost: O(N) bus messages + O(M) artifact
      reads. Independent of total wall time.
- [ ] team_demo.py passes 3/3 stable runs.

## 10. v2 ideas (not v1)

- Conditional edges (`if outcome of A == "skip" then run B`).
- Per-task retry policy (`retry: 3` re-spawns the agent on error).
- Map step (`for_each: paths -> spawn one worker per path`) — useful
  when the count is data-dependent.
- LLM-driven plan revision: if a task's `summary` indicates it found
  unexpected work, the orchestrator pauses, re-asks the dispatcher
  LLM whether to add new tasks to the plan, then resumes.
- Persistent run state file so a daemon-restart-recover path becomes
  trivial.
