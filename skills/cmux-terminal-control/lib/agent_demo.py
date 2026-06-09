"""Layer 4 demo — delegate to a real Claude Code agent.

Spawns `claude --dangerously-skip-permissions` in a fresh terminal panel,
asks it to write a small Python script + tests, waits for completion,
and verifies the artifacts on disk. Interactive mode (no /goal) — small
task that finishes in a single turn.

Run:
  python3 agent_demo.py

Optional:
  CMUX_SURF=<surface-uuid>   reuse an existing terminal panel
"""
import os
import subprocess
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

from cmux_term import Surface, ClaudeAgent
from cmux_term._rpc import rpc as _rpc, CmuxError


WORKDIR = "/tmp/cmux-agent-demo"


def _spawn_dedicated_terminal() -> str:
    listing = _rpc("surface.list", {"workspace_id": "workspace:1"})
    focused = next(
        (s["id"] for s in listing.get("surfaces", []) if s.get("focused")),
        None,
    ) or listing["surfaces"][0]["id"]
    r = _rpc(
        "surface.split",
        {"surface_id": focused, "direction": "right", "kind": "terminal"},
    )
    return r["surface_id"]


def main() -> None:
    if os.path.exists(WORKDIR):
        import shutil
        shutil.rmtree(WORKDIR)
    os.makedirs(WORKDIR)

    # Find any existing surface to split from — claude spawns its own
    # panel via surface.split with initial_command, no shell typing.
    listing = _rpc("surface.list", {"workspace_id": "workspace:1"})
    parent_sid = (
        os.environ.get("CMUX_SURF")
        or next((s["id"] for s in listing.get("surfaces", []) if s.get("focused")), None)
        or listing["surfaces"][0]["id"]
    )

    t0 = time.time()
    a = ClaudeAgent.spawn(parent_sid, cwd=WORKDIR, ready_timeout_ms=60_000)
    s = Surface.from_id(a.surface_id)
    print(f"[demo] claude ready in panel {a.surface_id} ({time.time() - t0:.1f}s)")

    # --- delegate a small task ---
    # notify="cmux": agent fires a cmux notification when done — push,
    # not poll, so our token cost stays flat regardless of task length.
    token = a.delegate(
        "Create a file fizzbuzz.py that defines `fizzbuzz(n)` returning "
        "'Fizz' for multiples of 3, 'Buzz' for multiples of 5, "
        "'FizzBuzz' for multiples of 15, else str(n). "
        "Also write tests/test_fizzbuzz.py with at least 4 tests. "
        "Run `python3 -m pytest tests/` until it passes. "
        "Do not ask for confirmation; this directory is sandboxed.",
        notify="cmux",
    )
    print(f"[demo] task delegated; will be notified by cmux when done")

    # --- wait for done — single push wait + disk artifact verification ---
    fb_path_for_wait = os.path.join(WORKDIR, "fizzbuzz.py")
    test_path_for_wait = os.path.join(WORKDIR, "tests", "test_fizzbuzz.py")
    try:
        a.wait_for_done(
            token,
            notify="cmux",
            timeout_ms=300_000,
            check_disk=[fb_path_for_wait, test_path_for_wait],
        )
    except Exception as e:
        print(f"[demo] FAILED waiting for done: {e}")
        print(f"[demo] last screen:\n{a.screen_tail(20)}")
        raise

    print(f"[demo] agent reported done ({time.time() - t0:.1f}s total)")

    # --- verify artifacts on disk ---
    fb_path = os.path.join(WORKDIR, "fizzbuzz.py")
    test_path = os.path.join(WORKDIR, "tests", "test_fizzbuzz.py")

    assert os.path.exists(fb_path), f"missing {fb_path}"
    assert os.path.exists(test_path), f"missing {test_path}"

    fb_src = open(fb_path).read()
    assert "def fizzbuzz" in fb_src, f"no fizzbuzz def:\n{fb_src}"

    # Run pytest from outside the panel to confirm it actually passes
    r = subprocess.run(
        ["python3", "-m", "pytest", "tests/", "-q"],
        cwd=WORKDIR, capture_output=True, text=True, timeout=30,
    )
    assert r.returncode == 0, (
        f"pytest failed (exit={r.returncode}):\n{r.stdout}\n{r.stderr}"
    )
    print(f"[demo] pytest from outside: PASS — {r.stdout.strip().splitlines()[-1]}")

    # --- exit claude cleanly + close the dedicated panel ---
    a.exit()
    time.sleep(1.5)
    s.close()

    print("\nLayer 4 (Agent CLI) demo PASSED")
    print(f"  fizzbuzz.py: {len(fb_src)} bytes")
    print(f"  test file:   {len(open(test_path).read())} bytes")
    print(f"  pytest:      green")


if __name__ == "__main__":
    main()
