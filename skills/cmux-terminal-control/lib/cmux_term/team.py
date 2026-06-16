"""cmux Agent Team — turn a task DAG into a running multi-agent team.

See docs/design/agent-team.md for the full spec. Quick summary:

  - Caller (or an LLM) emits a `Plan` of `Task` objects, each with
    natural-language `prompt`, declared `outputs`, and `needs` ids
    pointing at upstream tasks.
  - `Team.run(plan)` topologically schedules tasks: spawns each one
    in its own cmux panel running a Claude sub-agent, wires upstream
    artifact paths into the downstream prompt by string replacement,
    and consumes `done` bus messages via `AgentBus.wait_any`.
  - Returns a `RunResult` with per-task `TaskOutcome`s.

LLM concept ↔ cmux physical channel mapping:

  Task        → ClaudeAgent in a fresh panel (agent_id = task.id)
  done signal → bus message `kind=done`, `from=task.id`
  X → Y wiring → orchestrator substitutes $inputs.X.outputs[N] in Y's
                 prompt with X's artifact path
  peer talk   → bus `kind=note`; orchestrator just lists peer ids
                 in the prompt, doesn't mediate
  ordering    → topo sort; ready set advanced on each `done`

This file is pure glue — every primitive it uses already exists in
`cmux_term.{bus, agent, _rpc, flow}`.
"""

import json
import os
import re
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Callable, Dict, Iterable, List, Optional, Set

from . import raw
from ._rpc import CmuxError, TimeoutError, rpc
from .agent import AgentSession, ClaudeAgent
from .bus import AgentBus, AgentBusMessage, render_protocol_instructions
from .flow import Surface
from .layout import LayoutPlan, SplitOp, for_kind as layout_for_kind


_TASK_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,32}$")
_INPUT_REF_RE = re.compile(r"\$inputs\.([A-Za-z0-9_.:-]+)\.outputs\[(\d+)\]")


# -------- data classes --------


@dataclass
class Task:
    id: str
    prompt: str
    needs: List[str] = field(default_factory=list)
    inputs: List[str] = field(default_factory=list)
    outputs: List[str] = field(default_factory=list)
    role: str = "worker"
    peers: List[str] = field(default_factory=list)
    timeout_ms: int = 600_000
    panel_direction: str = "auto"   # "right" | "down" | "auto"
    extra_env: Dict[str, str] = field(default_factory=dict)
    # Panel lifecycle on `done`:
    # - "always" (default): close panel and free space — best for
    #   short / unimportant tasks where the artifact is the only
    #   thing the user cares about.
    # - "never": keep the agent's panel open and the claude CLI
    #   interactive after the task reports done. Use for long /
    #   important tasks the user may want to inspect or chat with
    #   afterwards.
    # - "auto": orchestrator picks. Currently: keep open if the
    #   task ran > 60s OR ever published a `needs_input` message.
    close_on_done: str = "always"
    # Optional path to a file holding additional context the agent
    # should read instead of receiving it inline in the prompt.
    # Useful when the prompt would otherwise exceed token budget.
    # The orchestrator references this path in the prompt; the agent
    # opens the file with its Read tool.
    context_file: Optional[str] = None
    # agent_cls is held by class identity; default ClaudeAgent. We
    # don't bake it into the dataclass to keep JSON-roundtrip clean.

    def __post_init__(self) -> None:
        if not _TASK_ID_RE.match(self.id):
            raise ValueError(f"Task id {self.id!r} must match {_TASK_ID_RE.pattern}")
        if self.panel_direction not in ("right", "down", "auto"):
            raise ValueError(f"panel_direction must be right|down|auto, got {self.panel_direction!r}")


@dataclass
class Plan:
    workspace: str                   # absolute filesystem path. Each task
                                     # spawns a NEW cmux workspace (top tab)
                                     # rooted at this cwd, then those tabs
                                     # are bundled under a named workspace
                                     # group so the whole team shows up as
                                     # one collapsible top-tab cluster.
    tasks: List[Task]
    name: str = ""                   # workspace-group title (e.g. "build #42")
    on_failure: str = "abort"        # "abort" | "isolate" | "continue"
    # If a task's prompt exceeds this byte budget, the orchestrator
    # auto-spills it to a context file under workspace/.cmux-team/
    # and replaces the inline prompt with a short pointer. Saves
    # tokens and keeps the chat tidy when prompts are large.
    spill_prompt_threshold_bytes: int = 4_000
    # Layout for the team's worker panels in its dedicated top tab.
    # "auto" (default): pick by task count + whether any task has
    #   role in {"main","coordinator","lead"} — uses tiled for 4+
    #   equal-priority tasks, main-vertical when there's a clear
    #   coordinator.
    # Or explicit: "main-vertical" | "main-horizontal"
    #            | "even-horizontal" | "even-vertical" | "tiled"
    layout: str = "auto"
    # Fraction of the screen given to the dispatcher panel in main-*.
    main_fraction: float = 0.6
    # Cap concurrent live workers per top tab. tmux can hold many but
    # readability degrades fast — beyond ~6 panels per tab the agent
    # CLI's status line wraps. New tabs spawn automatically when full.
    max_concurrency: int = 3

    def __post_init__(self) -> None:
        if self.on_failure not in ("abort", "isolate", "continue"):
            raise ValueError(f"on_failure must be abort|isolate|continue, got {self.on_failure!r}")
        # max_concurrency capped at 8 — beyond that panels become unusable.
        self.max_concurrency = max(1, min(8, self.max_concurrency))

    @classmethod
    def from_json(cls, s: str) -> "Plan":
        data = json.loads(s)
        tasks = [Task(**t) for t in data.pop("tasks", [])]
        return cls(tasks=tasks, **data)

    def validate(self) -> None:
        ids = [t.id for t in self.tasks]
        if len(set(ids)) != len(ids):
            raise CmuxError(f"duplicate task ids in plan: {ids}")
        id_set = set(ids)
        for t in self.tasks:
            for n in t.needs:
                if n not in id_set:
                    raise CmuxError(f"task {t.id!r} needs unknown task {n!r}")
            for p in t.peers:
                if p not in id_set:
                    raise CmuxError(f"task {t.id!r} peers unknown task {p!r}")
            # Validate $inputs.X.outputs[N] references
            for m in _INPUT_REF_RE.finditer(t.prompt):
                ref_id = m.group(1)
                idx = int(m.group(2))
                if ref_id not in id_set:
                    raise CmuxError(f"task {t.id!r} references unknown task {ref_id!r}")
                if ref_id not in t.needs:
                    raise CmuxError(
                        f"task {t.id!r} references {ref_id!r} but doesn't list it in `needs`"
                    )
                ref_task = next(rt for rt in self.tasks if rt.id == ref_id)
                if idx >= len(ref_task.outputs):
                    raise CmuxError(
                        f"task {t.id!r} references {ref_id}.outputs[{idx}] but it has only {len(ref_task.outputs)} outputs"
                    )
        # Cycle detection via DFS
        WHITE, GRAY, BLACK = 0, 1, 2
        color = {tid: WHITE for tid in id_set}
        deps = {t.id: list(t.needs) for t in self.tasks}

        def visit(node: str, stack: List[str]) -> None:
            if color[node] == GRAY:
                raise CmuxError(f"cycle in plan: {' -> '.join(stack + [node])}")
            if color[node] == BLACK:
                return
            color[node] = GRAY
            for d in deps[node]:
                visit(d, stack + [node])
            color[node] = BLACK

        for tid in id_set:
            if color[tid] == WHITE:
                visit(tid, [])

        if not os.path.isdir(self.workspace):
            raise CmuxError(f"workspace does not exist: {self.workspace}")


@dataclass
class TaskOutcome:
    task_id: str
    status: str = "pending"          # pending|running|done|failed|cancelled|skipped
    summary: str = ""
    artifacts: List[str] = field(default_factory=list)
    error: Optional[str] = None
    bus_messages: List[AgentBusMessage] = field(default_factory=list)
    panel_id: Optional[str] = None
    started_at: Optional[datetime] = None
    finished_at: Optional[datetime] = None


@dataclass
class RunResult:
    outcomes: Dict[str, TaskOutcome]
    started_at: datetime
    finished_at: datetime
    plan: Plan

    @property
    def all_done(self) -> bool:
        return all(o.status == "done" for o in self.outcomes.values())


# -------- orchestrator --------


class TeamRunError(CmuxError):
    pass


class Team:
    """Run a multi-agent `Plan` end-to-end. Stateful; one Team = one run."""

    def __init__(
        self,
        *,
        parent_surface_id: str,
        max_concurrency: int = 3,
        on_event: Optional[Callable[[Dict[str, Any]], None]] = None,
        agent_cls: type = ClaudeAgent,
    ) -> None:
        self.parent_surface_id = parent_surface_id
        self.max_concurrency = max_concurrency
        self.on_event = on_event or (lambda e: None)
        self.agent_cls = agent_cls
        self._cancelled = False
        self._state = None  # set in run() once a TeamState is constructed
        self._workspace: Optional[str] = None
        self._plan_name: str = ""
        self._team_root_surface_id: Optional[str] = None
        self._in_flight_panels: Dict[str, AgentSession] = {}
        self._anchor_surface_id: Optional[str] = None
        self._created_workspace_ids: List[str] = []
        # Per-tab tracking for layout
        self._tab_workers_count: int = 0
        self._tab_first_worker_surface: Optional[str] = None
        self._tab_last_worker_surface: Optional[str] = None
        # Layout plan + per-tab panel registry (panel[0] = tab root,
        # subsequent entries appended in spawn order so SplitOp's
        # parent_index resolves to a real surface).
        self._tab_panels: List[str] = []
        self._layout_plan: Optional[LayoutPlan] = None
        self._current_plan: Optional[Plan] = None
        # How many tasks still need a panel for the CURRENT tab —
        # used to size the layout dynamically (a 2-task plan makes
        # 2 panels, not the cap).
        self._tasks_remaining_for_tab: int = 0
        # cmux top-tab roots (surface ids) opened by this team. Top
        # tabs are torn down at end of run.
        self._team_workspace_id: Optional[str] = None
        self._team_workspace_count: int = 0
        self._team_workspaces: List[str] = []
        # Map task.id → top-tab root surface id, for naming/cleanup.
        self._task_to_tab_root: Dict[str, str] = {}
        # Agents whose panels we kept open after `done` (per task's
        # close_on_done policy). Reaped only at full teardown.
        self._kept_open_agents: Dict[str, AgentSession] = {}
        # All agents ever spawned, keyed by agent_id, used to look up
        # peers when deciding whether a top tab is now empty.
        self._all_agents: Dict[str, AgentSession] = {}
        # Live task ids per top-tab root. When a top tab's set goes
        # empty (all member tasks finished), the whole top tab is
        # closed. The root surface is kept alive until then so it can
        # serve as a stable split-anchor for siblings.
        self._tab_live_tasks: Dict[str, set] = {}

    # ----- public -----

    def run(
        self,
        plan: Plan,
        *,
        timeout_ms: int = 30 * 60_000,
        resume: bool = True,
        retry_failed: bool = True,
    ) -> RunResult:
        """Run a plan to completion.

        :param resume: if True (default) and a state.json from a prior
            run with an identical plan_hash exists, tasks already in
            ``done`` are skipped (their artifacts are reused via
            $inputs). Tasks left in ``running`` from a prior process
            are reset to ``pending`` and re-attempted.
        :param retry_failed: if True (default), tasks whose prior
            outcome was ``failed`` are also reset to ``pending`` and
            re-attempted. Set False to inspect failures without
            re-running them.
        """
        plan.validate()
        from .team_state import TeamState

        state = TeamState.load_or_fresh(plan, resume=resume)
        self._state = state
        plan.max_concurrency = min(plan.max_concurrency, self.max_concurrency)
        self._workspace = plan.workspace
        self._plan_name = plan.name or "team"
        self._team_root_surface_id = None
        self._in_flight_panels = {}
        self._anchor_surface_id = None
        self._tab_workers_count = 0
        self._tab_first_worker_surface = None
        self._tab_last_worker_surface = None
        self._tab_panels = []
        self._layout_plan = None
        self._current_plan = plan
        self._tasks_remaining_for_tab = len(plan.tasks)
        self._team_workspace_id = None
        self._team_workspace_count = 0
        self._team_workspaces = []
        self._task_to_tab_root = {}
        self._kept_open_agents = {}
        self._all_agents = {}
        self._tab_live_tasks = {}

        outcomes: Dict[str, TaskOutcome] = {
            t.id: TaskOutcome(task_id=t.id) for t in plan.tasks
        }
        # Resume: hydrate outcomes from durable state.
        resumed_done: List[str] = []
        if resume:
            for tid, hydrated in state.to_resumable_outcomes().items():
                outcomes[tid] = hydrated
                resumed_done.append(tid)
            # If retry_failed=False, also keep failed/skipped tasks
            # in their terminal state so they don't re-run.
            if not retry_failed:
                for tid, ts in state.tasks.items():
                    if ts.status in ("failed", "skipped"):
                        outcomes[tid].status = ts.status
                        outcomes[tid].error = ts.error
                        outcomes[tid].summary = ts.summary
                        outcomes[tid].artifacts = list(ts.artifacts)
        in_flight: Dict[str, AgentSession] = {}
        agent_to_task: Dict[str, str] = {}        # agent_id → task_id (same value)
        bus = AgentBus()

        started = datetime.now()
        deadline = time.time() + timeout_ms / 1000.0

        def remaining_ms() -> int:
            return max(500, int((deadline - time.time()) * 1000))

        def ready_tasks() -> List[Task]:
            return [
                t for t in plan.tasks
                if outcomes[t.id].status == "pending"
                and all(outcomes[d].status == "done" for d in t.needs)
                and not any(outcomes[d].status in ("failed", "cancelled", "skipped") for d in t.needs)
            ]

        emit_lock = threading.Lock()

        def emit(kind: str, **fields: Any) -> None:
            evt = {"event": kind, "ts": datetime.now().isoformat(), **fields}
            with emit_lock:
                self.on_event(evt)

        # Observer threads: per-task transcript tail that emits
        # `task.tool_use` / `task.thinking` events while the worker runs.
        # Backed by chat_source.ChatStream when AGENT_KIND is set;
        # silently skipped otherwise.
        observer_stop = threading.Event()
        observer_threads: List[threading.Thread] = []

        def start_observer(task_id: str, agent: AgentSession) -> None:
            if getattr(agent, "_chat_stream", None) is None:
                return
            def run_observer():
                try:
                    for ev in agent._chat_stream.poll(timeout=24 * 3600.0, interval=0.1):
                        if observer_stop.is_set():
                            return
                        if ev.kind == "tool_use":
                            emit("task.tool_use",
                                 task=task_id,
                                 tool=ev.tool_name,
                                 input_keys=list((ev.tool_input or {}).keys()))
                        elif ev.kind == "thinking" and ev.text:
                            emit("task.thinking", task=task_id, text=ev.text[:200])
                except Exception:
                    pass
            t = threading.Thread(target=run_observer, daemon=True)
            t.start()
            observer_threads.append(t)

        emit("plan.start", plan=plan.name, tasks=[t.id for t in plan.tasks],
             resumed_done=resumed_done)
        if resumed_done:
            emit("plan.resumed", done=resumed_done, progress=state.progress())

        try:
            # Main scheduling loop
            while True:
                if self._cancelled:
                    self._cancel_in_flight(in_flight, outcomes)
                    break

                # Dispatch newly-ready tasks up to concurrency cap
                while (len(in_flight) < plan.max_concurrency
                       and ready_tasks()
                       and not self._cancelled):
                    task = ready_tasks()[0]
                    outcomes[task.id].status = "running"
                    outcomes[task.id].started_at = datetime.now()
                    self._in_flight_panels = in_flight   # share for spawn fallback
                    agent = self._spawn_for_task(task=task)
                    outcomes[task.id].panel_id = agent.surface_id
                    in_flight[task.id] = agent
                    agent_to_task[task.id] = task.id

                    prompt = self._assemble_prompt(task, plan, outcomes)
                    agent.delegate(prompt, notify="bus")
                    state.mark_running(task.id, panel_id=agent.surface_id)
                    emit("task.spawned", task=task.id, panel=agent.surface_id)
                    start_observer(task.id, agent)

                # If nothing in flight and nothing ready, we're done
                if not in_flight:
                    break

                # Wait for any in-flight agent to publish
                pending_agents = list(in_flight.keys())
                try:
                    msg = bus.wait_any(
                        agents=pending_agents,
                        kind=None,                 # accept done|error|needs_input|progress
                        timeout_ms=min(remaining_ms(), 60_000),
                    )
                except TimeoutError:
                    if time.time() >= deadline:
                        for tid, ag in list(in_flight.items()):
                            outcomes[tid].status = "failed"
                            outcomes[tid].error = "team timeout"
                            outcomes[tid].finished_at = datetime.now()
                        self._cancel_in_flight(in_flight, outcomes)
                        raise TeamRunError(f"team run hit timeout ({timeout_ms}ms)")
                    continue           # transient, keep waiting

                self._handle_message(msg, in_flight, outcomes, plan, emit)

        finally:
            observer_stop.set()
            self._tear_down(in_flight)

        finished = datetime.now()
        emit("plan.finished",
             done=[t for t, o in outcomes.items() if o.status == "done"],
             failed=[t for t, o in outcomes.items() if o.status in ("failed", "cancelled")])
        return RunResult(outcomes=outcomes, started_at=started, finished_at=finished, plan=plan)

    def cancel(self) -> None:
        """Request abortive shutdown — the loop will tear down on the next iteration."""
        self._cancelled = True

    # ----- internals -----

    def _pick_direction(
        self, task: Task, last_panel_id: str, in_flight: Dict[str, AgentSession]
    ) -> str:
        # Retained for compat; ignored when we route through new workspaces.
        return task.panel_direction if task.panel_direction != "auto" else "right"

    # Max worker panels per top tab. Beyond this, a new top tab
    # opens automatically. 6 lets a 2×3 tiled grid fit comfortably.
    PANELS_PER_TAB: int = 6

    def _resolve_close_policy(self, task: Task, outcome: "TaskOutcome") -> str:
        """Decide whether a finished task's panel stays open.
        Returns "close" or "keep"."""
        if task.close_on_done == "never":
            return "keep"
        if task.close_on_done == "always":
            return "close"
        # auto: keep if the task ran long OR ever hit needs_input.
        had_input_request = any(
            m.kind == "needs_input" for m in outcome.bus_messages
        )
        if had_input_request:
            return "keep"
        if outcome.started_at and outcome.finished_at:
            duration = (outcome.finished_at - outcome.started_at).total_seconds()
            if duration > 60:
                return "keep"
        return "close"

    def _resolve_layout_kind(self, plan: Plan, n_panels: int) -> str:
        """Pick a layout preset by task count + main-role presence."""
        kind = plan.layout
        if kind != "auto":
            return kind
        has_main = any(
            getattr(t, "role", "") in ("main", "coordinator", "lead")
            for t in plan.tasks
        )
        if n_panels <= 3:
            return "main-vertical"
        if n_panels == 4:
            return "main-vertical" if has_main else "tiled"
        return "tiled"

    def _ensure_layout_plan(self, plan: Plan) -> LayoutPlan:
        """Compute SplitOps for one full top-tab batch sized for the
        EXACT remaining task count. Cached per top tab; reset to None
        whenever a new top tab opens."""
        if self._layout_plan is None:
            n = max(1, min(self.PANELS_PER_TAB, self._tasks_remaining_for_tab))
            kind = self._resolve_layout_kind(plan, n)
            self._layout_plan = layout_for_kind(
                kind, n_workers=n, main_fraction=plan.main_fraction,
            )
        return self._layout_plan

    def _spawn_for_task(self, *, task: Task) -> AgentSession:
        """Dynamically allocate a panel for `task`.

        Strategy: NO pre-built empty panels — split on demand. When a
        task spawns:
          1. Count currently-LIVE worker panels in the active top tab.
          2. Pick parent + divider so the new panel takes 1/(N+1) of
             the parent's space — exactly like tmux even-split.
          3. If no live panels yet, open a top tab and the new panel
             IS the top tab's root.
          4. Rename the new panel after the task id (top-tab-bar label).

        When a task completes (in _close_agent), we close its panel —
        cmux automatically rebalances the remaining siblings to fill
        the freed space. So the user only ever sees running panels,
        and they always evenly tile the available area.
        """
        plan_obj = self._current_plan

        # Count live worker panels in the current top tab.
        live_workers: List[AgentSession] = [
            ag for ag_id, ag in self._in_flight_panels.items() if ag is not None
        ]
        n_live = len(live_workers)

        # Group tasks by what's RUNNING RIGHT NOW: if any sibling is
        # in flight, join its top tab (they're visually related — the
        # user watches them race side by side). If nothing's running,
        # open a fresh top tab — this task is independent in time.
        target_root: Optional[str] = None
        if live_workers:
            target_root = self._task_to_tab_root.get(live_workers[-1].agent_id)
        need_new_top_tab = target_root is None

        if need_new_top_tab:
            resp = rpc("workspace.top_tab.create", {
                "workspace_id": self._team_workspace_id or "workspace:1",
                "focus": True if not self._tab_panels else False,
            })
            new_tab_root = resp.get("surface_id")
            if not new_tab_root or new_tab_root == self.parent_surface_id:
                raise CmuxError(f"workspace.top_tab.create failed: {resp}")
            tab_label = (plan_obj.name or task.id).strip() or "team"
            self._team_root_surface_id = new_tab_root
            self._tab_panels = [new_tab_root]
            self._team_workspaces.append(new_tab_root)
            self._team_workspace_count += 1
            time.sleep(2.5)
            # Rename top tab (top-tab-bar label) using the dedicated RPC.
            try:
                rpc("workspace.top_tab.rename", {
                    "workspace_id": self._team_workspace_id or "workspace:1",
                    "surface_id": new_tab_root,
                    "title": tab_label[:32],
                })
            except CmuxError:
                pass
            # Rename the surface itself too — shows in pane tab bar
            # if the top tab grows multiple panes.
            try:
                rpc("tab.action", {
                    "surface_id": new_tab_root,
                    "action": "rename",
                    "title": task.id,
                })
            except CmuxError:
                pass
            self._launch_claude_in_surface(new_tab_root, cwd=self._workspace)
            agent = self.agent_cls.__new__(self.agent_cls)
            agent.surface_id = new_tab_root
            agent.cwd = self._workspace
            agent.agent_id = task.id
            agent._spawned = True
            self._tasks_remaining_for_tab = max(0, self._tasks_remaining_for_tab - 1)
            if self._team_root_surface_id:
                self._task_to_tab_root[task.id] = self._team_root_surface_id
            self._all_agents[task.id] = agent
            return agent

        # Otherwise: split into the target top tab (the one containing
        # this task's predecessor). Prefer a live sibling already in
        # that tab; fall back to the tab's root anchor.
        sibling_panels = [
            ag.surface_id for ag in live_workers
            if self._task_to_tab_root.get(ag.agent_id) == target_root
        ]
        if sibling_panels:
            parent_panel = sibling_panels[-1]
        else:
            parent_panel = target_root  # the tab root is always alive
        # Direction: alternate to spread panels across both axes —
        # 1st new: right, 2nd: down, 3rd: right, 4th: down, ...
        direction = "right" if n_live % 2 == 1 else "down"
        # Divider position (the new panel's share of parent):
        # we want the new panel to take "what makes the layout even".
        # With N live + 1 new = N+1 total: each gets 1/(N+1) of total
        # space. Parent currently occupies 1 slot (1/N of total), so
        # new = 1/(N+1) of total = 1/(2*N/N+1) ≈ 0.5 (split parent in half).
        # Simplest: 0.5 even split — cmux rebalances on-close.
        divider = 0.5

        spawned = self.agent_cls.spawn(
            parent_panel,
            cwd=self._workspace,
            direction=direction,
            initial_divider_position=divider,
        )
        spawned.agent_id = task.id
        # Rename the new panel after the task.
        try:
            rpc("tab.action", {
                "surface_id": spawned.surface_id,
                "action": "rename",
                "title": task.id,
            })
        except CmuxError:
            pass
        self._tab_panels.append(spawned.surface_id)
        self._tasks_remaining_for_tab = max(0, self._tasks_remaining_for_tab - 1)
        # Bind this task to the top tab it actually went into (the
        # target_root computed above), NOT the most-recent root.
        if target_root:
            self._task_to_tab_root[task.id] = target_root
        elif self._team_root_surface_id:
            self._task_to_tab_root[task.id] = self._team_root_surface_id
        self._all_agents[task.id] = spawned
        return spawned

    def _prebuild_layout_panels(self) -> None:
        """Apply every SplitOp in the active layout to create empty
        terminal panels at exact tmux-style proportions. Each split
        appends one panel id to `self._tab_panels`."""
        layout_plan = self._layout_plan
        if layout_plan is None:
            return
        for op in layout_plan.ops:
            if op.parent_index >= len(self._tab_panels):
                raise CmuxError(
                    f"layout SplitOp references panel[{op.parent_index}] "
                    f"but only {len(self._tab_panels)} exist"
                )
            parent_id = self._tab_panels[op.parent_index]
            split_resp = rpc("surface.split", {
                "surface_id": parent_id,
                "direction": op.direction,
                "type": "terminal",
                "working_directory": self._workspace,
                "initial_divider_position": op.divider,
            })
            new_id = split_resp.get("surface_id")
            if not new_id:
                raise CmuxError(f"surface.split returned no surface_id: {split_resp}")
            self._tab_panels.append(new_id)
        # Brief settle so the new PTYs are ready before we type into them.
        time.sleep(1.0)

    def _launch_claude_in_surface(self, surface_id: str, cwd: str) -> None:
        """Send the claude launch command + handle the trust prompt.
        Mirrors ClaudeAgent.spawn but for a pre-existing surface."""
        from . import atomic, raw as _raw
        import time as _time
        cmd = self.agent_cls.LAUNCH_CMD
        atomic.type_text(surface_id, cmd, timeout_ms=4000)
        atomic.press(surface_id, "enter", timeout_ms=4000)
        ready_markers = list(self.agent_cls.READY_MARKERS) + [
            getattr(self.agent_cls, "TRUST_PROMPT_MARKER", "Yes, I trust this folder"),
        ]
        # Poll screen_hash; only fetch screen_text when hash changes.
        deadline = _time.time() + 60.0
        last_hash = None
        seen = None
        while _time.time() < deadline:
            try:
                h = _raw.screen_hash(surface_id)
            except Exception:
                _time.sleep(0.4)
                continue
            if h != last_hash:
                last_hash = h
                try:
                    txt = _raw.screen_text(surface_id)
                except Exception:
                    _time.sleep(0.2)
                    continue
                for m in ready_markers:
                    if m in txt:
                        seen = m
                        break
                if seen:
                    break
            _time.sleep(0.4)
        if seen and seen == getattr(self.agent_cls, "TRUST_PROMPT_MARKER", None):
            _time.sleep(0.3)
            _raw.send_text(surface_id, "1")
            _time.sleep(0.2)
            _raw.send_key(surface_id, "enter")
            # Wait for ready post-trust
            deadline2 = _time.time() + 30.0
            while _time.time() < deadline2:
                try:
                    txt = _raw.screen_text(surface_id)
                except Exception:
                    _time.sleep(0.4)
                    continue
                for m in self.agent_cls.READY_MARKERS:
                    if m in txt:
                        return
                _time.sleep(0.5)

    def _workspace_for(self, task: Task) -> str:
        # All tasks share the plan workspace by default. Subclassing
        # Team can override per-task isolation if needed.
        return getattr(self, "_workspace", None) or task.extra_env.get("CWD") or "/tmp"

    def _assemble_prompt(self, task: Task, plan: Plan, outcomes: Dict[str, TaskOutcome]) -> str:
        # Substitute $inputs.X.outputs[N]
        def sub(m: "re.Match") -> str:
            ref_id, idx_s = m.group(1), m.group(2)
            up = next(t for t in plan.tasks if t.id == ref_id)
            idx = int(idx_s)
            return up.outputs[idx]

        body = _INPUT_REF_RE.sub(sub, task.prompt)

        # Auto-spill big prompts to a context file so the inline
        # message stays small. Saves tokens when the agent's prompt
        # would be many KB. Skip if the task already declares a
        # context_file (caller did it manually).
        if (not task.context_file
                and len(body.encode("utf-8")) > plan.spill_prompt_threshold_bytes):
            spill_dir = os.path.join(plan.workspace, ".cmux-team")
            os.makedirs(spill_dir, exist_ok=True)
            spill_path = os.path.join(spill_dir, f"{task.id}.prompt.md")
            with open(spill_path, "w") as f:
                f.write(body)
            # Mutate task in place — both for prompt assembly below
            # and so the agent sees the context_file pointer.
            task.context_file = spill_path
            body = (
                f"The detailed task description was too long for chat; "
                f"read it from {spill_path} via your Read tool. The "
                f"INPUTS / OUTPUTS / PEERS sections below still apply."
            )

        upstream_descs = []
        for need in task.needs:
            up = next(t for t in plan.tasks if t.id == need)
            up_outcome = outcomes[need]
            for path in up.outputs:
                desc = up_outcome.summary or up.role
                upstream_descs.append(f"  - {path}  ({desc})")

        outputs_block = ""
        if task.outputs:
            outputs_block = "\n[OUTPUTS]\nWhen done, the following files MUST exist:\n" + \
                "\n".join(f"  - {p}" for p in task.outputs)

        peers_block = ""
        if task.peers:
            peers_block = (
                f"\n[PEERS]\nYou may message any of these teammate agents with "
                f"`kind: note` over the cmux agent bus: {task.peers}. They will "
                f"receive your messages. Use this for collaboration, not for "
                f"signaling completion (use `kind: done` for that)."
            )

        inputs_block = ""
        if upstream_descs or task.inputs:
            extra = "\n".join(f"  - {p}" for p in task.inputs)
            inputs_block = "\n[INPUTS]\nFiles available on disk:\n" + \
                "\n".join(upstream_descs + ([extra] if extra else []))

        context_block = ""
        if task.context_file:
            context_block = (
                f"\n[CONTEXT]\nThe full task context lives in this file:\n"
                f"  {task.context_file}\n"
                f"Read it with your Read tool BEFORE doing anything else. "
                f"It contains the detailed instructions, examples, and "
                f"any extra material the task description above keeps short."
            )

        bus_block = "\n\n[BUS PROTOCOL]\n" + render_protocol_instructions(
            agent=task.id,
            ref=task.id,             # one bus thread per task
            done_summary_hint="≤120 chars",
        )

        prelude = (
            f"You are sub-agent {task.id!r}, role: {task.role}.\n"
            f"This is a coordinated multi-agent run. Workspace: {plan.workspace}.\n"
        )

        return prelude + inputs_block + context_block + "\n\n[TASK]\n" + body + outputs_block + peers_block + bus_block

    def _handle_message(
        self,
        msg: AgentBusMessage,
        in_flight: Dict[str, AgentSession],
        outcomes: Dict[str, TaskOutcome],
        plan: Plan,
        emit: Callable[..., None],
    ) -> None:
        agent_id = msg.from_
        if agent_id not in in_flight:
            # Stale message (from a peer or earlier run); ignore
            return
        outcome = outcomes[agent_id]
        outcome.bus_messages.append(msg)

        if msg.kind == "done":
            outcome.status = "done"
            outcome.summary = msg.summary
            outcome.artifacts = list(msg.artifacts)
            outcome.finished_at = datetime.now()
            # Verify declared outputs exist on disk
            task = next(t for t in plan.tasks if t.id == agent_id)
            missing = [p for p in task.outputs if not os.path.exists(p)]
            if missing:
                outcome.status = "failed"
                outcome.error = f"declared outputs missing: {missing}"
                if self._state is not None:
                    self._state.mark_failed(agent_id, outcome.error)
                emit("task.failed", task=agent_id, error=outcome.error)
                self._maybe_propagate_failure(agent_id, in_flight, outcomes, plan)
                self._close_agent(in_flight.pop(agent_id), in_flight=in_flight)
                return
            if self._state is not None:
                self._state.mark_done(agent_id, outcome.summary, outcome.artifacts)
            emit("task.done", task=agent_id, summary=outcome.summary, artifacts=outcome.artifacts)
            agent_done = in_flight.pop(agent_id)
            policy = self._resolve_close_policy(task, outcome)
            if policy == "keep":
                # Keep panel open AND keep the claude CLI alive so the
                # user can ask follow-ups. Track the agent so teardown
                # can still reach it at end of run.
                self._kept_open_agents[agent_id] = agent_done
                emit("task.kept_open", task=agent_id,
                     reason="close_on_done=never or auto-kept")
            else:
                self._close_agent(agent_done, in_flight=in_flight)
        elif msg.kind == "error":
            outcome.status = "failed"
            outcome.error = msg.summary or "agent reported error"
            outcome.finished_at = datetime.now()
            if self._state is not None:
                self._state.mark_failed(agent_id, outcome.error)
            emit("task.failed", task=agent_id, error=outcome.error)
            self._maybe_propagate_failure(agent_id, in_flight, outcomes, plan)
            self._close_agent(in_flight.pop(agent_id), in_flight=in_flight)
        elif msg.kind == "needs_input":
            emit("task.needs_input", task=agent_id, question=msg.summary)
            # v1: we don't auto-answer. The orchestrator surfaces the
            # question via emit; if the dispatcher's on_event handler
            # decides to abort, it sets self._cancelled = True.
        elif msg.kind == "progress":
            emit("task.progress", task=agent_id, message=msg.summary)
        elif msg.kind == "log":
            emit("task.log", task=agent_id, message=msg.summary)
        else:
            emit("task.message", task=agent_id, kind=msg.kind, message=msg.summary)

    def _maybe_propagate_failure(
        self,
        failed_id: str,
        in_flight: Dict[str, AgentSession],
        outcomes: Dict[str, TaskOutcome],
        plan: Plan,
    ) -> None:
        if plan.on_failure == "abort":
            self._cancelled = True
        elif plan.on_failure == "isolate":
            # Mark every transitive downstream as skipped
            downstream = self._downstream_of(failed_id, plan)
            for d in downstream:
                if outcomes[d].status == "pending":
                    outcomes[d].status = "skipped"
                    outcomes[d].error = f"upstream {failed_id} failed"
                    if self._state is not None:
                        self._state.mark_skipped(d, outcomes[d].error)
        # "continue" → do nothing, siblings keep running, downstream
        # will eventually be marked skipped by ready_tasks() guard.

    def _downstream_of(self, root: str, plan: Plan) -> Set[str]:
        children: Dict[str, List[str]] = {t.id: [] for t in plan.tasks}
        for t in plan.tasks:
            for n in t.needs:
                children[n].append(t.id)
        out: Set[str] = set()
        stack = [root]
        while stack:
            cur = stack.pop()
            for c in children[cur]:
                if c not in out:
                    out.add(c)
                    stack.append(c)
        return out

    def _cancel_in_flight(
        self, in_flight: Dict[str, AgentSession], outcomes: Dict[str, TaskOutcome]
    ) -> None:
        for tid, agent in list(in_flight.items()):
            outcomes[tid].status = "cancelled"
            outcomes[tid].finished_at = datetime.now()
            if self._state is not None:
                self._state.mark_cancelled(tid)
            try:
                # Send a polite cancel note over bus, then Ctrl+C the panel
                raw.send_key(agent.surface_id, "ctrl+c")
            except Exception:
                pass
        for ag in list(in_flight.values()):
            self._close_agent(ag)
        in_flight.clear()

    def _close_agent(self, agent: AgentSession,
                     in_flight: Optional[Dict[str, "AgentSession"]] = None) -> None:
        """A task finished — close its panel. When the last task in
        its top tab finishes, close the whole top tab too.

        `in_flight` is the orchestrator's live-task map (without this
        agent — it's already been popped). Peers are detected by
        looking for other in_flight tasks bound to the same top-tab
        root.
        """
        try:
            agent.exit()
        except Exception:
            pass
        time.sleep(0.3)
        tab_root = self._task_to_tab_root.get(agent.agent_id)
        peer_alive = False
        if tab_root and in_flight:
            for other_id in in_flight:
                if self._task_to_tab_root.get(other_id) == tab_root:
                    peer_alive = True
                    break
        if peer_alive:
            # Close just this panel — siblings have their own panes
            # (post-split they're independent), so closing root is OK.
            try:
                Surface.from_id(agent.surface_id).close()
            except Exception:
                pass
            if agent.surface_id in self._tab_panels:
                try:
                    self._tab_panels.remove(agent.surface_id)
                except ValueError:
                    pass
        else:
            # Last task in this top tab — close the whole top tab.
            # Use this agent's own surface_id (still alive) as the
            # anchor; the original tab_root may already be a dead
            # surface from an earlier _close_agent call.
            self._close_top_tab(agent.surface_id)
            if tab_root and tab_root != agent.surface_id:
                if tab_root in self._team_workspaces:
                    try:
                        self._team_workspaces.remove(tab_root)
                    except ValueError:
                        pass
                if self._team_root_surface_id == tab_root:
                    self._team_root_surface_id = None

    def _close_top_tab(self, root_sid: str) -> None:
        try:
            rpc("workspace.top_tab.close", {
                "workspace_id": self._team_workspace_id or "workspace:1",
                "surface_id": root_sid,
            })
        except CmuxError:
            try:
                Surface.from_id(root_sid).close()
            except Exception:
                pass
        if root_sid in self._team_workspaces:
            try:
                self._team_workspaces.remove(root_sid)
            except ValueError:
                pass
        if root_sid in self._tab_panels:
            try:
                self._tab_panels.remove(root_sid)
            except ValueError:
                pass
        if self._team_root_surface_id == root_sid:
            self._team_root_surface_id = None

    def _tear_down(self, in_flight: Dict[str, AgentSession]) -> None:
        # Tear down at end of run:
        # 1. /exit any still-running agent CLIs
        # 2. close the entire top tab (layoutTab) for each one we
        #    opened — this kills all panels inside it in one shot
        #    and removes the top-tab-bar entry so the workspace looks
        #    exactly like before the team ran.
        # Stop every still-running agent (in-flight + kept-open).
        for ag in list(in_flight.values()) + list(self._kept_open_agents.values()):
            try:
                ag.exit()
            except Exception:
                pass
        time.sleep(0.5)
        # Close every team-owned top tab. We pass any surface from
        # that tab; daemon resolves it to the layoutTab and closes it.
        for root_sid in self._team_workspaces:
            if root_sid == self.parent_surface_id:
                continue
            try:
                rpc("workspace.top_tab.close", {
                    "workspace_id": self._team_workspace_id or "workspace:1",
                    "surface_id": root_sid,
                })
            except CmuxError:
                # Fallback: close the surface directly (works when
                # the layoutTab has only one panel left).
                try:
                    Surface.from_id(root_sid).close()
                except Exception:
                    pass


