"""Full dispatcher-acceptor loop with revisions.

This tests the REAL scenario:
  1. dispatcher sends initial task
  2. sub-agent does work, self-reviews, fires cmux notification
  3. dispatcher (us) receives push → spot-checks artifact → finds something
     missing → sends a follow-up chat with concrete feedback
  4. sub-agent does revision, fires another cmux notification
  5. dispatcher receives push → re-checks → accepts → done

We never scrape the agent's full screen. We only verify on disk and read
the bottom 10 lines of the panel for context. Token cost stays flat.
"""

import os
import shutil
import subprocess
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

from cmux_term import Surface, ClaudeAgent
from cmux_term._rpc import rpc as _rpc

WORKDIR = "/tmp/cmux-agent-fullloop"


def _parent() -> str:
    listing = _rpc("surface.list", {"workspace_id": "workspace:1"})
    return (
        os.environ.get("CMUX_PARENT")
        or next((s["id"] for s in listing.get("surfaces", []) if s.get("focused")), None)
        or listing["surfaces"][0]["id"]
    )


def main() -> None:
    if os.path.exists(WORKDIR):
        shutil.rmtree(WORKDIR)
    os.makedirs(WORKDIR)

    print("[T0] dispatcher: spawning Claude in dedicated panel")
    a = ClaudeAgent.spawn(_parent(), cwd=WORKDIR, ready_timeout_ms=60_000)
    print(f"[T0] panel={a.surface_id}")

    # ---- Round 1: initial dispatch ----
    print("\n[R1] dispatcher: sending initial task")
    t1_start = time.time()
    t1 = a.delegate(
        "Create stats.py with a function `mean(xs)` that returns the "
        "arithmetic mean of a list of numbers. Add tests/test_stats.py "
        "with at least 2 tests. Run pytest until green. Do not ask for "
        "confirmation.",
        notify="cmux",
    )
    print("[R1] dispatcher: waiting (push, no polling)...")
    a.wait_for_done(
        t1,
        notify="cmux",
        timeout_ms=300_000,
        check_disk=[f"{WORKDIR}/stats.py", f"{WORKDIR}/tests/test_stats.py"],
    )
    print(f"[R1] notification received ({time.time() - t1_start:.1f}s)")

    # ---- Round 1 acceptance ----
    src = open(f"{WORKDIR}/stats.py").read()
    print(f"[R1] artifact stats.py ({len(src)} bytes):")
    for line in src.splitlines():
        print(f"     | {line}")

    # Spot-check: does it handle empty list? We bet it doesn't and ask.
    has_empty_handling = (
        "if not xs" in src or "len(xs) == 0" in src or "ZeroDivisionError" in src
        or "raise" in src
    )
    print(f"[R1] dispatcher review: handles empty list? {has_empty_handling}")

    # ---- Round 2: revision request ----
    if not has_empty_handling:
        print("\n[R2] dispatcher: requesting revision")
        t2_start = time.time()
        t2 = a.chat(
            "I noticed `mean([])` would crash with ZeroDivisionError. "
            "Update stats.py to raise ValueError('empty input') instead. "
            "Add a test for the empty case. Re-run pytest.",
            notify="cmux",
        )
        print("[R2] dispatcher: waiting...")
        a.wait_for_done(t2, notify="cmux", timeout_ms=300_000)
        print(f"[R2] notification received ({time.time() - t2_start:.1f}s)")

        src2 = open(f"{WORKDIR}/stats.py").read()
        tests2 = open(f"{WORKDIR}/tests/test_stats.py").read()
        print(f"[R2] revised stats.py ({len(src2)} bytes):")
        for line in src2.splitlines():
            print(f"     | {line}")

        has_value_error = "ValueError" in src2 and "empty" in src2.lower()
        has_empty_test = "[]" in tests2 or "empty" in tests2.lower()
        assert has_value_error, f"revision didn't add ValueError: {src2}"
        assert has_empty_test, f"no empty-list test: {tests2}"

    # ---- Final acceptance: pytest from outside ----
    r = subprocess.run(
        ["python3", "-m", "pytest", "tests/", "-q"],
        cwd=WORKDIR, capture_output=True, text=True, timeout=30,
    )
    assert r.returncode == 0, f"pytest failed: {r.stdout}\n{r.stderr}"
    pytest_summary = r.stdout.strip().splitlines()[-1]
    print(f"\n[ACCEPT] pytest from outside: {pytest_summary}")

    # ---- close ----
    a.exit()
    time.sleep(1.5)
    Surface.from_id(a.surface_id).close()

    print("\n✓ DISPATCHER-ACCEPTOR FULL LOOP PASSED")
    print(f"  - 2 round-trips (dispatch → push → accept → revise → push → accept)")
    print(f"  - artifacts on disk: stats.py, tests/test_stats.py")
    print(f"  - {pytest_summary}")


if __name__ == "__main__":
    main()
