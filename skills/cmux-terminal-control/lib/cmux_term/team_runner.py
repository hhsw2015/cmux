"""
team_runner — entry point that turns plan.json into a running cmux team.

Usage::

    python -m cmux_term.team_runner run plan.json
    python -m cmux_term.team_runner run plan.json --no-resume   # discard prior state
    python -m cmux_term.team_runner run plan.json --no-retry    # keep failed as failed
    python -m cmux_term.team_runner status plan.json            # show progress
    python -m cmux_term.team_runner reset plan.json             # archive state
    python -m cmux_term.team_runner cancel plan.json            # mark running -> cancelled
                                                                # (best-effort — does
                                                                # not kill panels)
    python -m cmux_term.team_runner schema                      # print JSON schema doc

This is the single LLM-facing entry point. The agent emits plan.json,
calls `python -m cmux_term.team_runner run plan.json`, and the runtime
takes care of everything else (validation, top-tab/panel allocation,
$inputs interpolation, prompt-file spill, DAG scheduling, durable
state, resume on crash, artifact verification).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, Dict

from ._rpc import rpc, CmuxError
from .team import RunResult, Team, TeamRunError
from .team_schema import PlanValidationError, dump_schema_doc, load_plan
from .team_state import TeamState, _state_path


def _resolve_parent_surface() -> str:
    """Resolve a sane parent surface_id when the caller doesn't pass
    one explicitly: prefer the env-injected CMUX_SURFACE_ID (set when
    the user invokes us from inside a cmux pane), fall back to the
    workspace's current focused surface."""
    env = os.environ.get("CMUX_SURFACE_ID")
    if env:
        return env
    try:
        r = rpc("surface.current", {})
        sid = r.get("surface_id")
        if sid:
            return sid
    except CmuxError:
        pass
    try:
        r = rpc("surface.list", {"workspace_id": "workspace:1"})
        for s in r.get("surfaces", []):
            if s.get("focused") and s.get("in_window"):
                return s["id"]
        for s in r.get("surfaces", []):
            if s.get("in_window"):
                return s["id"]
    except CmuxError:
        pass
    raise SystemExit(
        "cannot resolve parent surface_id: pass --parent-surface <uuid> or "
        "set CMUX_SURFACE_ID, and make sure cmux is running."
    )


def _emit(event: Dict[str, Any]) -> None:
    """Default event sink — print one JSON line per event so callers
    can tail it. Override by passing on_event=... to Team()."""
    print(json.dumps(event, ensure_ascii=False, separators=(",", ":")), flush=True)


def cmd_run(args: argparse.Namespace) -> int:
    try:
        rp = load_plan(args.plan)
    except PlanValidationError as e:
        sys.stderr.write(f"plan validation failed at {e.path}: {e.message}\n")
        return 2
    plan = rp.plan
    timeout_ms = args.timeout_ms or rp.timeout_ms
    parent_surface_id = args.parent_surface or _resolve_parent_surface()
    team = Team(
        parent_surface_id=parent_surface_id,
        on_event=_emit,
        max_concurrency=plan.max_concurrency,
    )
    try:
        result: RunResult = team.run(
            plan,
            timeout_ms=timeout_ms,
            resume=not args.no_resume,
            retry_failed=not args.no_retry,
        )
    except TeamRunError as e:
        sys.stderr.write(f"team run failed: {e}\n")
        return 1
    # Verify artifacts declared in plan.json (separate from team's
    # internal output check, which uses task.outputs).
    failures = []
    for tid, expected in rp.expect_artifacts.items():
        for path in expected:
            if not os.path.exists(path):
                failures.append(f"task={tid} missing expect_artifact {path}")
    summary = {
        "event": "plan.summary",
        "plan": plan.name,
        "outcomes": {tid: o.status for tid, o in result.outcomes.items()},
        "duration_ms": int((result.finished_at - result.started_at).total_seconds() * 1000),
        "expect_artifact_failures": failures,
    }
    print(json.dumps(summary, ensure_ascii=False, separators=(",", ":")), flush=True)
    if failures:
        return 1
    bad = [tid for tid, o in result.outcomes.items() if o.status not in ("done",)]
    return 0 if not bad else 1


def cmd_status(args: argparse.Namespace) -> int:
    try:
        rp = load_plan(args.plan)
    except PlanValidationError as e:
        sys.stderr.write(f"plan validation failed at {e.path}: {e.message}\n")
        return 2
    state = TeamState.load_or_fresh(rp.plan, resume=True)
    out = {
        "plan": rp.plan.name,
        "state_file": _state_path(rp.plan),
        "started_at": state.started_at,
        "last_updated_at": state.last_updated_at,
        "progress": state.progress(),
        "tasks": {
            tid: {
                "status": ts.status,
                "summary": ts.summary,
                "artifacts": ts.artifacts,
                "error": ts.error,
                "attempts": ts.attempts,
                "started_at": ts.started_at,
                "finished_at": ts.finished_at,
            }
            for tid, ts in state.tasks.items()
        },
    }
    print(json.dumps(out, indent=2, ensure_ascii=False))
    return 0


def cmd_reset(args: argparse.Namespace) -> int:
    try:
        rp = load_plan(args.plan)
    except PlanValidationError as e:
        sys.stderr.write(f"plan validation failed at {e.path}: {e.message}\n")
        return 2
    path = _state_path(rp.plan)
    if not os.path.exists(path):
        print(f"no state at {path}", flush=True)
        return 0
    if args.purge:
        os.unlink(path)
        print(f"removed {path}", flush=True)
    else:
        # Force fresh by reloading with resume=False (this archives the
        # prior state.json under the same directory).
        TeamState.load_or_fresh(rp.plan, resume=False)
        print(f"archived prior state at {path}", flush=True)
    return 0


def cmd_cancel(args: argparse.Namespace) -> int:
    """Mark any running tasks as cancelled in state.json. Best-effort:
    this does NOT kill claude panels. Useful when a runner died with
    panels still running and you want resume to retry them cleanly."""
    try:
        rp = load_plan(args.plan)
    except PlanValidationError as e:
        sys.stderr.write(f"plan validation failed at {e.path}: {e.message}\n")
        return 2
    state = TeamState.load_or_fresh(rp.plan, resume=True)
    cancelled = []
    for tid, ts in state.tasks.items():
        if ts.status == "running":
            state.mark_cancelled(tid)
            cancelled.append(tid)
    print(json.dumps({"cancelled": cancelled}, ensure_ascii=False))
    return 0


def cmd_schema(_args: argparse.Namespace) -> int:
    print(dump_schema_doc())
    return 0


def main(argv: list = None) -> int:
    p = argparse.ArgumentParser(
        prog="python -m cmux_term.team_runner",
        description="Run a cmux multi-agent plan defined by plan.json.",
    )
    sub = p.add_subparsers(dest="command", required=True)

    pr = sub.add_parser("run", help="run a plan")
    pr.add_argument("plan", help="path to plan.json (or '-' for stdin)")
    pr.add_argument("--no-resume", action="store_true",
                    help="ignore any prior state.json and start fresh")
    pr.add_argument("--no-retry", action="store_true",
                    help="on resume, keep prior 'failed' tasks failed (don't re-run)")
    pr.add_argument("--timeout-ms", type=int, default=None,
                    help="override plan.timeout_ms (whole-run budget)")
    pr.add_argument("--parent-surface", default=None,
                    help="surface_id used to anchor the team's first top tab. "
                         "Defaults to $CMUX_SURFACE_ID or the focused surface.")
    pr.set_defaults(handler=cmd_run)

    ps = sub.add_parser("status", help="show progress for a plan")
    ps.add_argument("plan")
    ps.set_defaults(handler=cmd_status)

    prst = sub.add_parser("reset", help="archive (or purge) state.json so the next run starts clean")
    prst.add_argument("plan")
    prst.add_argument("--purge", action="store_true", help="delete state.json instead of archiving")
    prst.set_defaults(handler=cmd_reset)

    pc = sub.add_parser("cancel", help="mark running tasks as cancelled in state.json (best-effort)")
    pc.add_argument("plan")
    pc.set_defaults(handler=cmd_cancel)

    psch = sub.add_parser("schema", help="print the plan.json schema doc (paste into LLM prompt)")
    psch.set_defaults(handler=cmd_schema)

    args = p.parse_args(argv)
    return args.handler(args)


if __name__ == "__main__":
    raise SystemExit(main())
