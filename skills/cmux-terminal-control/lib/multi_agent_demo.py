"""Multi-agent demo: dispatcher coordinates 3 parallel Claude workers.

Pattern (matches docs/design/agent-bus.md):
  - Dispatcher spawns 3 Claude sub-agents, each in its own panel.
  - Each is given a tiny independent task (compute a stat over a
    different file in /tmp/cmux-multi/).
  - All 3 publish results via the agent bus (`notify="bus"`).
  - Dispatcher does ONE `bus.wait_all(agents=[a1,a2,a3], kind='done')`
    to receive 3 push notifications, then reads the artifact files
    and synthesizes.

Token economics: dispatcher's incremental cost per agent = 1 RPC for
delegate + 1 RPC for the bus message + reading one small artifact
file. No screen scraping during execution.

Run:  python3 multi_agent_demo.py
"""

import json
import os
import shutil
import subprocess
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

from cmux_term import ClaudeAgent, AgentBus, Surface, AgentFleet
from cmux_term._rpc import rpc as _rpc

WORKDIR = "/tmp/cmux-multi"


def _parent() -> str:
    listing = _rpc("surface.list", {"workspace_id": "workspace:1"})
    return (
        os.environ.get("CMUX_PARENT")
        or next((s["id"] for s in listing.get("surfaces", []) if s.get("focused")), None)
        or listing["surfaces"][0]["id"]
    )


def _seed_inputs():
    if os.path.exists(WORKDIR):
        shutil.rmtree(WORKDIR)
    os.makedirs(WORKDIR)
    # Three input files. Workers each compute a different stat over
    # their assigned file.
    inputs = {
        "nums_a.txt": "1\n2\n3\n4\n5\n",                  # mean = 3
        "nums_b.txt": "10\n20\n30\n40\n",                 # max = 40
        "nums_c.txt": "1\n1\n2\n3\n5\n8\n",               # sum = 20
    }
    for name, body in inputs.items():
        with open(os.path.join(WORKDIR, name), "w") as f:
            f.write(body)


def main() -> None:
    _seed_inputs()
    parent = _parent()

    print("[dispatcher] spawning 3 Claude workers")
    fleet = AgentFleet()
    workers = []
    tasks = [
        ("worker_a", "nums_a.txt", "compute the arithmetic mean", "stat_a.json", "mean"),
        ("worker_b", "nums_b.txt", "find the max value",          "stat_b.json", "max"),
        ("worker_c", "nums_c.txt", "compute the sum",             "stat_c.json", "sum"),
    ]

    bus = AgentBus()
    refs = {}

<<<<<<< HEAD
    # First worker splits right off dispatcher; subsequent workers
    # split DOWN off the previous worker so we don't keep narrowing
    # the rightmost column. Result: dispatcher | (a) (b) (c) stacked.
    last_panel = parent
    for i, (agent_id, inp, op_desc, out_name, op_key) in enumerate(tasks):
        direction = "right" if i == 0 else "down"
=======
    for agent_id, inp, op_desc, out_name, op_key in tasks:
>>>>>>> d33b9b83c (feat(agent-bus): cmux-native multi-agent message bus)
        a = ClaudeAgent(
            surface_id="",  # placeholder; real id set after spawn
            cwd=WORKDIR,
            agent_id=agent_id,
        )
<<<<<<< HEAD
        spawned = ClaudeAgent.spawn(last_panel, cwd=WORKDIR, direction=direction)
=======
        # Spawn brand-new panel (not reusing dispatcher's) so each
        # worker has isolated context.
        spawned = ClaudeAgent.spawn(parent, cwd=WORKDIR)
>>>>>>> d33b9b83c (feat(agent-bus): cmux-native multi-agent message bus)
        # Adopt: copy spawned panel into our agent_id-stable wrapper
        # (so bus messages carry our chosen id).
        a.surface_id = spawned.surface_id
        a._spawned = True
<<<<<<< HEAD
        last_panel = spawned.surface_id
=======
>>>>>>> d33b9b83c (feat(agent-bus): cmux-native multi-agent message bus)
        fleet.add(a)
        workers.append((agent_id, a, inp, out_name, op_key))

        ref = a.delegate(
            f"You are sub-agent {agent_id}. Read {inp} (one integer per "
            f"line, in the current directory) and {op_desc}. Write the "
            f"result to {out_name} as JSON: "
            f'{{"{op_key}": <value>, "input": "{inp}"}}. '
            f"Verify the file exists and contains the expected JSON, "
            f"then signal completion via the cmux agent bus.",
            notify="bus",
        )
        refs[agent_id] = ref
        print(f"[dispatcher]   delegated to {agent_id} (ref={ref[:8]}…) panel={a.surface_id[:8]}")

    print(f"\n[dispatcher] waiting for all 3 workers (push, single bus.wait_all RPC stream)…")
    t0 = time.time()
    msgs = bus.wait_all(
        agents=[a_id for a_id, *_ in workers],
        kind="done",
        timeout_ms=300_000,
    )
    print(f"[dispatcher] all 3 done in {time.time()-t0:.1f}s")

    # Verify on disk + synthesize
    print("\n[dispatcher] reading artifacts:")
    summary = {}
    for m in msgs:
        # Find the matching task
        match = next((t for t in workers if t[0] == m.from_), None)
        if not match:
            print(f"  ! got {m.from_} but no matching worker?")
            continue
        agent_id, _, _, out_name, op_key = match
        path = os.path.join(WORKDIR, out_name)
        assert os.path.exists(path), f"{agent_id}: artifact {path} missing"
        data = json.loads(open(path).read())
        summary[agent_id] = data
        print(f"  - {agent_id}: {data} (msg.summary={m.summary!r})")

    # Sanity-check the math
    assert summary.get("worker_a", {}).get("mean") in (3, 3.0), summary
    assert summary.get("worker_b", {}).get("max") == 40, summary
    assert summary.get("worker_c", {}).get("sum") == 20, summary

    print("\n✓ MULTI-AGENT DEMO PASSED — 3 parallel workers, push-notified via bus")
    print(f"  total wall: {time.time()-t0:.1f}s")
    print(f"  results:    {summary}")

    # Shutdown
    fleet.shutdown()
    time.sleep(1.0)
    for _, a, *_ in workers:
        try:
            Surface.from_id(a.surface_id).close()
        except Exception:
            pass


if __name__ == "__main__":
    main()
