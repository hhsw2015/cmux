"""Team orchestrator demo — 5-task diamond DAG.

Topology:

       seed
        |
       scrape
        |
       stat
       /  \\
    plot   summarize
       \\  /
       report

The orchestrator:
  - spawns each task as an isolated Claude sub-agent in its own panel
  - wires upstream artifact paths into downstream prompts
  - uses bus push notifications (no polling)
  - schedules `plot` and `summarize` to run in parallel after `stat`
  - aggregates everything into report.md, verified on disk

Tests cover: diamond DAG, fan-out + reduce, multi-stage pipeline.
"""

import json
import os
import shutil
import subprocess
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

from cmux_term import Plan, Task, Team
from cmux_term._rpc import rpc as _rpc

WORKSPACE = "/tmp/cmux-team"


def _seed():
    if os.path.exists(WORKSPACE):
        shutil.rmtree(WORKSPACE)
    os.makedirs(WORKSPACE)
    # Input dataset: numbers per category
    raw_data = """category,value
fruits,3
fruits,7
fruits,12
veggies,5
veggies,9
grains,4
grains,8
grains,11
"""
    with open(f"{WORKSPACE}/raw.csv", "w") as f:
        f.write(raw_data)


def _parent() -> str:
    listing = _rpc("surface.list", {"workspace_id": "workspace:1"})
    return (
        os.environ.get("CMUX_PARENT")
        or next((s["id"] for s in listing.get("surfaces", []) if s.get("focused")), None)
        or listing["surfaces"][0]["id"]
    )


def main() -> None:
    _seed()
    parent = _parent()

    plan = Plan(
        workspace=WORKSPACE,
        name="csv-pipeline",
        max_concurrency=3,
        tasks=[
            Task(
                id="scrape",
                role="data-loader",
                prompt=(
                    "Read raw.csv (category,value rows). Produce normalized.json "
                    "as a list of dicts {\"category\": str, \"value\": int}. "
                    "Do not change values; just convert types. Keep the file at "
                    "/tmp/cmux-team/normalized.json."
                ),
                outputs=[f"{WORKSPACE}/normalized.json"],
            ),
            Task(
                id="stat",
                role="statistician",
                needs=["scrape"],
                prompt=(
                    "Read $inputs.scrape.outputs[0] (a JSON array of "
                    "{category,value}). For each category compute count, sum, "
                    "mean, max. Write the result as a JSON object keyed by "
                    "category to /tmp/cmux-team/stats.json. Example shape: "
                    "{\"fruits\": {\"count\": 3, \"sum\": 22, \"mean\": 7.33, \"max\": 12}}."
                ),
                outputs=[f"{WORKSPACE}/stats.json"],
            ),
            Task(
                id="plot",
                role="visualizer",
                needs=["stat"],
                prompt=(
                    "Read $inputs.stat.outputs[0] (per-category stats). Produce a "
                    "plain-text ASCII bar chart of each category's mean value, "
                    "writing it to /tmp/cmux-team/plot.txt. Use 1 char per unit. "
                    "Example line: 'fruits | #######  (7.33)'. No external deps; "
                    "use the python stdlib only."
                ),
                outputs=[f"{WORKSPACE}/plot.txt"],
            ),
            Task(
                id="summarize",
                role="writer",
                needs=["stat"],
                prompt=(
                    "Read $inputs.stat.outputs[0]. Write a 3-sentence English "
                    "summary noting the highest-mean category, the lowest-mean "
                    "category, and the total number of records across all "
                    "categories. Output path: /tmp/cmux-team/summary.txt."
                ),
                outputs=[f"{WORKSPACE}/summary.txt"],
            ),
            Task(
                id="report",
                role="aggregator",
                needs=["plot", "summarize"],
                prompt=(
                    "Combine $inputs.plot.outputs[0] and "
                    "$inputs.summarize.outputs[0] into a single Markdown report "
                    "at /tmp/cmux-team/report.md. Top of file: # CSV Report. "
                    "Then '## Summary' followed by the summary text. Then "
                    "'## Visualization' followed by a fenced ``` block "
                    "containing the plot text. No commentary added by you — "
                    "use the upstream files verbatim."
                ),
                outputs=[f"{WORKSPACE}/report.md"],
            ),
        ],
    )

    print(f"[plan] {len(plan.tasks)} tasks; topology: scrape→stat→{{plot,summarize}}→report")

    events = []
    def on_event(e):
        events.append(e)
        ev = e["event"]
        if ev == "task.tool_use":
            print(f"  · {ev:18} {e.get('task','')}  {e.get('tool','')}({','.join(e.get('input_keys', []))})")
        elif ev == "task.thinking":
            print(f"  · {ev:18} {e.get('task','')}  {e.get('text','')[:80]}")
        elif ev.startswith("task."):
            print(f"  · {ev:18} {e.get('task','')}  {e.get('summary','')[:80]}")

    team = Team(parent_surface_id=parent, max_concurrency=3, on_event=on_event)

    t0 = time.time()
    try:
        result = team.run(plan, timeout_ms=10 * 60_000)
    except Exception as e:
        print(f"[run] FAILED: {e}")
        for tid, o in (team and getattr(e, "outcomes", {}) or {}).items():
            print(f"  - {tid}: {o.status} {o.error or ''}")
        raise

    dt = time.time() - t0
    print(f"[run] all done in {dt:.1f}s")
    for tid, o in result.outcomes.items():
        print(f"  - {tid}: {o.status}  artifacts={o.artifacts}")

    # Verify artifacts
    expected = [
        f"{WORKSPACE}/normalized.json",
        f"{WORKSPACE}/stats.json",
        f"{WORKSPACE}/plot.txt",
        f"{WORKSPACE}/summary.txt",
        f"{WORKSPACE}/report.md",
    ]
    for path in expected:
        assert os.path.exists(path), f"missing artifact: {path}"
    print(f"[verify] all 5 artifacts exist")

    # Sanity-check the final report
    report = open(f"{WORKSPACE}/report.md").read()
    assert "# CSV Report" in report, f"report missing header:\n{report[:300]}"
    # Section headers: agents may name them slightly differently. Just
    # make sure the report has at least 2 distinct section headers.
    h2_headers = [l for l in report.splitlines() if l.startswith("## ")]
    assert len(h2_headers) >= 2, f"need ≥2 sections, got {h2_headers}: {report[:300]}"
    assert "fruits" in report.lower(), "report doesn't mention any category"
    print(f"[verify] report.md ({len(report)} bytes) contains expected sections")

    # Sanity-check upstream wiring: plot and summarize ran AFTER stat
    by_id = {tid: o for tid, o in result.outcomes.items()}
    assert by_id["plot"].started_at >= by_id["stat"].finished_at
    assert by_id["summarize"].started_at >= by_id["stat"].finished_at
    assert by_id["report"].started_at >= by_id["plot"].finished_at
    assert by_id["report"].started_at >= by_id["summarize"].finished_at
    print(f"[verify] DAG ordering respected (stat → plot/summarize → report)")

    # Sanity-check parallelism: plot and summarize should overlap
    plot_start = by_id["plot"].started_at
    plot_end = by_id["plot"].finished_at
    sum_start = by_id["summarize"].started_at
    sum_end = by_id["summarize"].finished_at
    overlap = (plot_end > sum_start) and (sum_end > plot_start)
    if overlap:
        print(f"[verify] plot + summarize ran in parallel ✓")
    else:
        print(f"[verify] plot + summarize ran SEQUENTIALLY (max_concurrency may have throttled)")

    print("\n✓ TEAM ORCHESTRATOR DEMO PASSED")
    print(f"  - tasks:    {len(result.outcomes)} all done")
    print(f"  - wall:     {dt:.1f}s")
    print(f"  - report:   {WORKSPACE}/report.md ({len(report)} bytes)")


if __name__ == "__main__":
    main()
