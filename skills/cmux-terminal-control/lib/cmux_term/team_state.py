"""
team_state — durable per-plan state so runs can be resumed after a
crash, kill, or operator-initiated stop.

State layout
------------
For a plan rooted at ``<workspace>``, the state directory is::

    <workspace>/.cmux-team/<plan_name_or_hash>/state.json

state.json schema (version 1)::

    {
      "version": 1,
      "plan_hash": "<sha256 of canonical plan>",
      "started_at": "2026-06-10T12:00:00Z",
      "last_updated_at": "...",
      "tasks": {
        "<task_id>": {
          "status": "pending|running|done|failed|cancelled|skipped",
          "summary": "...",
          "artifacts": ["/abs/path", ...],
          "error": null,
          "started_at": "...",
          "finished_at": "...",
          "panel_id": null,
          "attempts": 0,
          "last_failure": null
        }
      }
    }

Resume policy
-------------
On `Team.run()` startup, the runtime calls ``State.load(plan)``:

  - If a state.json exists for an IDENTICAL plan_hash, it is loaded.
    Tasks with status=done are skipped (their outcomes are kept and
    their artifacts are still passed to descendants via $inputs).
    Tasks with status in {failed, cancelled, running} are reset to
    pending and re-run (a previous `running` indicates the prior
    process died mid-flight).
  - If plan_hash differs, the prior state is moved aside to
    state.<old_hash>.json and a fresh state is started — we never
    silently apply old outcomes to a new plan.
  - If the user passes resume=False to the runner, prior state is
    archived rather than consumed.

The runtime persists after every state transition (spawn / done /
fail / skip / teardown). Persistence is best-effort: a write failure
emits a warning but does not interrupt the run.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import tempfile
from dataclasses import asdict, dataclass, field, is_dataclass
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

from .team import Plan, Task, TaskOutcome

STATE_VERSION = 1


def plan_hash(plan: Plan) -> str:
    """Stable hash of the plan's task graph + structural settings.
    Cosmetic fields (name, layout, main_fraction, max_concurrency,
    spill threshold) are deliberately excluded — changing those should
    NOT discard valid prior outcomes."""
    canon: Dict[str, Any] = {
        "workspace": plan.workspace,
        "on_failure": plan.on_failure,
        "tasks": [
            {
                "id": t.id,
                "prompt": t.prompt,
                "needs": list(t.needs),
                "outputs": list(t.outputs),
                "inputs": list(t.inputs),
                "role": t.role,
                "panel_direction": t.panel_direction,
                "close_on_done": t.close_on_done,
                "context_file": t.context_file,
                "timeout_ms": t.timeout_ms,
                "extra_env": dict(sorted(t.extra_env.items())),
            }
            for t in sorted(plan.tasks, key=lambda x: x.id)
        ],
    }
    return hashlib.sha256(
        json.dumps(canon, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def _state_dir(plan: Plan) -> str:
    name = plan.name or "default"
    safe = "".join(c if c.isalnum() or c in "_.-" else "_" for c in name)
    return os.path.join(plan.workspace, ".cmux-team", safe or "default")


def _state_path(plan: Plan) -> str:
    return os.path.join(_state_dir(plan), "state.json")


@dataclass
class TaskState:
    status: str = "pending"
    summary: str = ""
    artifacts: List[str] = field(default_factory=list)
    error: Optional[str] = None
    started_at: Optional[str] = None
    finished_at: Optional[str] = None
    panel_id: Optional[str] = None
    attempts: int = 0
    last_failure: Optional[str] = None

    @classmethod
    def from_outcome(cls, o: TaskOutcome) -> "TaskState":
        return cls(
            status=o.status,
            summary=o.summary,
            artifacts=list(o.artifacts),
            error=o.error,
            started_at=_iso(o.started_at),
            finished_at=_iso(o.finished_at),
            panel_id=o.panel_id,
        )


@dataclass
class TeamState:
    """In-memory mirror of state.json. Methods mutate + persist."""

    plan: Plan
    plan_hash: str
    started_at: str
    last_updated_at: str
    tasks: Dict[str, TaskState] = field(default_factory=dict)

    # ---- persistence ----

    @classmethod
    def fresh(cls, plan: Plan) -> "TeamState":
        now = _now_iso()
        st = cls(
            plan=plan,
            plan_hash=plan_hash(plan),
            started_at=now,
            last_updated_at=now,
            tasks={t.id: TaskState() for t in plan.tasks},
        )
        st.persist()
        return st

    @classmethod
    def load_or_fresh(cls, plan: Plan, *, resume: bool = True) -> "TeamState":
        path = _state_path(plan)
        if not resume or not os.path.exists(path):
            if resume and os.path.exists(path):
                _archive(path, "no-resume")
            return cls.fresh(plan)
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except (json.JSONDecodeError, OSError):
            _archive(path, "unreadable")
            return cls.fresh(plan)
        if data.get("version") != STATE_VERSION:
            _archive(path, f"v{data.get('version')}-incompatible")
            return cls.fresh(plan)
        prior_hash = data.get("plan_hash")
        new_hash = plan_hash(plan)
        if prior_hash != new_hash:
            _archive(path, f"hash-mismatch-{prior_hash[:8] if prior_hash else 'none'}")
            return cls.fresh(plan)
        tasks: Dict[str, TaskState] = {}
        for tid in (t.id for t in plan.tasks):
            raw = (data.get("tasks") or {}).get(tid) or {}
            ts = TaskState(
                status=raw.get("status", "pending"),
                summary=raw.get("summary", ""),
                artifacts=list(raw.get("artifacts") or []),
                error=raw.get("error"),
                started_at=raw.get("started_at"),
                finished_at=raw.get("finished_at"),
                panel_id=raw.get("panel_id"),
                attempts=int(raw.get("attempts") or 0),
                last_failure=raw.get("last_failure"),
            )
            # A `running` entry means the prior process died mid-task.
            # Reset to pending so the runtime re-tries it.
            if ts.status in ("running", "cancelled"):
                ts.status = "pending"
            # Keep `failed` as-is so the runtime can decide per-policy:
            # default behaviour is to retry failed tasks on resume.
            tasks[tid] = ts
        st = cls(
            plan=plan,
            plan_hash=new_hash,
            started_at=data.get("started_at") or _now_iso(),
            last_updated_at=_now_iso(),
            tasks=tasks,
        )
        st.persist()
        return st

    def persist(self) -> None:
        path = _state_path(self.plan)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.last_updated_at = _now_iso()
        body = {
            "version": STATE_VERSION,
            "plan_hash": self.plan_hash,
            "plan_name": self.plan.name,
            "started_at": self.started_at,
            "last_updated_at": self.last_updated_at,
            "tasks": {tid: asdict(ts) for tid, ts in self.tasks.items()},
        }
        try:
            _atomic_write(path, json.dumps(body, indent=2, sort_keys=True))
        except OSError as e:
            # Best-effort: never abort a run for state-write failure.
            print(f"[team-state] WARN: persist failed: {e}", flush=True)

    # ---- transitions ----

    def mark_running(self, task_id: str, panel_id: Optional[str] = None) -> None:
        ts = self.tasks[task_id]
        ts.status = "running"
        ts.attempts += 1
        ts.started_at = _now_iso()
        ts.finished_at = None
        ts.error = None
        ts.panel_id = panel_id
        self.persist()

    def mark_done(self, task_id: str, summary: str, artifacts: List[str]) -> None:
        ts = self.tasks[task_id]
        ts.status = "done"
        ts.summary = summary
        ts.artifacts = list(artifacts)
        ts.finished_at = _now_iso()
        ts.error = None
        self.persist()

    def mark_failed(self, task_id: str, error: str) -> None:
        ts = self.tasks[task_id]
        ts.status = "failed"
        ts.error = error
        ts.last_failure = _now_iso()
        ts.finished_at = _now_iso()
        self.persist()

    def mark_skipped(self, task_id: str, reason: str) -> None:
        ts = self.tasks[task_id]
        ts.status = "skipped"
        ts.error = reason
        ts.finished_at = _now_iso()
        self.persist()

    def mark_cancelled(self, task_id: str) -> None:
        ts = self.tasks[task_id]
        if ts.status in ("done", "failed", "skipped"):
            return
        ts.status = "cancelled"
        ts.finished_at = _now_iso()
        self.persist()

    # ---- queries ----

    def status(self, task_id: str) -> str:
        return self.tasks[task_id].status

    def is_done(self, task_id: str) -> bool:
        return self.tasks[task_id].status == "done"

    def progress(self) -> Dict[str, int]:
        out = {"pending": 0, "running": 0, "done": 0, "failed": 0, "skipped": 0, "cancelled": 0}
        for ts in self.tasks.values():
            out[ts.status] = out.get(ts.status, 0) + 1
        return out

    def to_resumable_outcomes(self) -> Dict[str, TaskOutcome]:
        """Hydrate already-done tasks into TaskOutcome objects so the
        runtime can wire their artifacts into descendants without
        re-running them."""
        out: Dict[str, TaskOutcome] = {}
        for tid, ts in self.tasks.items():
            if ts.status != "done":
                continue
            out[tid] = TaskOutcome(
                task_id=tid,
                status="done",
                summary=ts.summary,
                artifacts=list(ts.artifacts),
                started_at=_parse_iso(ts.started_at),
                finished_at=_parse_iso(ts.finished_at),
                panel_id=ts.panel_id,
            )
        return out


# ---------- helpers ----------


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _iso(dt: Optional[datetime]) -> Optional[str]:
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.isoformat()


def _parse_iso(s: Optional[str]) -> Optional[datetime]:
    if not s:
        return None
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        return None


def _atomic_write(path: str, body: str) -> None:
    fd, tmp = tempfile.mkstemp(prefix=".state.", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(body)
        os.replace(tmp, path)
    finally:
        try:
            if os.path.exists(tmp):
                os.unlink(tmp)
        except OSError:
            pass


def _archive(path: str, tag: str) -> None:
    if not os.path.exists(path):
        return
    base = os.path.dirname(path)
    archive = os.path.join(base, f"state.{tag}.{int(datetime.now(timezone.utc).timestamp())}.json")
    try:
        shutil.move(path, archive)
    except OSError:
        try:
            os.unlink(path)
        except OSError:
            pass
