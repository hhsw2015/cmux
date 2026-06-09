"""Complex real-dev demo using all 3 layers + batch.

Scenario: build a tiny Python CLI that filters lines by regex.
- L3 run_script: scaffold the project (deps, dirs, init files)
- L3 vim_edit (content): write the test file (composite)
- L3 vim_edit (content): write a buggy implementation
- L1 raw + L2 expect: run pytest fast, see FAIL
- L2 atomic press/type/expect: open vim and fix the bug interactively
- L3 batch.run_steps: re-run pytest, git init/add/commit in ONE RPC
- Truth: re-run from outside the panel, assert exit code & content.

Each layer is chosen deliberately and the choice rationale is logged.
"""
import os
import shutil
import subprocess
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
from cmux_term import Surface, raw, atomic, batch
from cmux_term.batch import send_line, send_line_steps, lines, wait_text, wait_idle, sleep_ms
from cmux_term._rpc import rpc as _rpc, CmuxError

ROOT = "/tmp/cmux-realdev2"


def _spawn_dedicated_terminal() -> str:
    """Always split a fresh terminal off the focused surface so we don't
    stomp on the user's active panel. Caller is responsible for closing
    via Surface.close()."""
    listing = _rpc("surface.list", {"workspace_id": "workspace:1"})
    focused = next(
        (s["id"] for s in listing.get("surfaces", []) if s.get("focused")),
        None,
    )
    if not focused:
        # fall back to the first listed surface
        if not listing.get("surfaces"):
            raise SystemExit("no surfaces in workspace:1")
        focused = listing["surfaces"][0]["id"]
    r = _rpc(
        "surface.split",
        {"surface_id": focused, "direction": "right", "kind": "terminal"},
    )
    return r["surface_id"]


SURF = os.environ.get("CMUX_SURF") or _spawn_dedicated_terminal()
_OWNED = "CMUX_SURF" not in os.environ


def step(label, fn):
    print(f"\n=== {label} ===", flush=True)
    t0 = time.time()
    fn()
    dt = time.time() - t0
    print(f"    OK ({dt*1000:.0f}ms)", flush=True)


def main():
    if os.path.exists(ROOT):
        shutil.rmtree(ROOT)
    os.makedirs(ROOT)

    s = Surface.from_id(SURF)
    s.wait_ready()
    s.type_line(f"cd {ROOT}")

    # ---- L3 run_script: scaffold (high confidence, multi-line, never want
    #      to inspect intermediate steps individually) ----
    def s1_scaffold():
        s.run_script("""
set -e
mkdir -p src tests
touch src/__init__.py tests/__init__.py
echo 'from src.grep import grep_lines' > tests/__init__.py
""", expect_after=os.path.basename(ROOT))
        for p in ("src/__init__.py", "tests/__init__.py"):
            assert os.path.exists(f"{ROOT}/{p}"), f"missing {p}"
    step("S1 scaffold (L3 run_script — high-confidence batch)", s1_scaffold)

    # ---- L3 vim_edit: write test file (composite — handles open/i/type/wq) ----
    def s2_write_test():
        TEST = (
            "import re\n"
            "from src.grep import grep_lines\n"
            "\n"
            "def test_basic():\n"
            "    out = grep_lines(['apple', 'banana', 'cherry'], 'an')\n"
            "    assert out == ['banana']\n"
            "\n"
            "def test_multiple():\n"
            "    out = grep_lines(['a1', 'b2', 'a3', 'c4'], 'a[0-9]')\n"
            "    assert out == ['a1', 'a3']\n"
        )
        s.vim_edit(f"{ROOT}/tests/test_grep.py", content=TEST)
        got = open(f"{ROOT}/tests/test_grep.py").read()
        assert "grep_lines" in got and "test_multiple" in got, got
    step("S2 vim_edit test_grep.py (L3 composite — low-effort verified open/edit/save)",
         s2_write_test)

    # ---- L3 vim_edit: write BUGGY implementation (uses match instead of search) ----
    def s3_write_impl_buggy():
        IMPL = (
            "import re\n"
            "\n"
            "def grep_lines(lines, pattern):\n"
            "    rx = re.compile(pattern)\n"
            # bug: re.match anchors at start; for 'an' against 'banana' returns None
            "    return [l for l in lines if rx.match(l)]\n"
        )
        s.vim_edit(f"{ROOT}/src/grep.py", content=IMPL)
        got = open(f"{ROOT}/src/grep.py").read()
        assert "rx.match" in got, got
    step("S3 vim_edit src/grep.py with .match() bug (L3 composite)",
         s3_write_impl_buggy)

    # ---- L1 raw + 1 trailing L2 expect: run pytest, expect FAIL ----
    #      High confidence the *command* will run; we just want to see if
    #      tests pass or fail. 1 send + 1 wait = 2 RPCs total.
    def s4_pytest_fail():
        marker = "PYTEST_FAIL_MARK"
        raw.send_text(s.id, f"python3 -m pytest tests/ 2>&1 | tail -20; echo {marker}\n")
        atomic.expect(s.id, marker, timeout_ms=15000)
        screen = s.screen()
        assert "FAILED" in screen or "failed" in screen, f"expected FAIL, got:\n{screen[-500:]}"
        # Truth check from outside
        r = subprocess.run(
            ["python3", "-m", "pytest", "tests/"], cwd=ROOT,
            capture_output=True, text=True,
        )
        assert r.returncode != 0, f"pytest unexpectedly passed: {r.stdout}"
    step("S4 pytest → FAIL (L1 raw + 1 L2 expect — 2 RPCs)", s4_pytest_fail)

    # ---- L2 atomic: open vim, navigate to bug line, fix interactively ----
    #      LOW CONFIDENCE: line numbers depend on prior edit, cursor must
    #      land precisely; verify each motion.
    def s5_interactive_fix():
        s.launch(f"/usr/bin/vi -u NONE -N {ROOT}/src/grep.py", expect="grep.py")
        s.wait_idle(300, 1500)
        # Use ex command to substitute — the deterministic way. Even though
        # we said "atomic", :%s is the right tool here because regex match
        # is unambiguous. The L2-ness comes from verifying each press.
        s.press("escape")          # ensure normal mode
        s.exec_ex(":%s/rx.match/rx.search/g")
        s.wait_idle(200, 1000)
        s.exec_ex(":wq")
        s.wait_idle(400, 3000)
        got = open(f"{ROOT}/src/grep.py").read()
        assert "rx.search" in got and "rx.match" not in got, got
    step("S5 vim fix .match → .search (L2 atomic — verify-each-step)",
         s5_interactive_fix)

    # ---- L3 batch.run_steps: re-test + git init/add/commit in ONE RPC ----
    #      Predictable shell chain, no branching, daemon-side fail-fast.
    def s6_test_and_commit():
        # Pack the whole git chain into ONE shell-level command using &&.
        # That bypasses any per-line input buffering issues.
        git_chain = (
            "git init -q && git add -A && "
            "git -c user.email=t@t -c user.name=t commit -q -m 'feat: grep_lines' && "
            "git log --oneline"
        )
        steps = [
            *send_line_steps("python3 -m pytest tests/ -q 2>&1 | tail -5"),
            wait_text("passed", timeout_ms=10000),
            *send_line_steps(git_chain),
            wait_text("feat: grep_lines", timeout_ms=8000),
        ]
        result = s.run_steps(steps, timeout_ms=25000)
        assert result["completed"] == result["total"], result
        # Truth checks
        r = subprocess.run(["python3", "-m", "pytest", "tests/", "-q"],
                           cwd=ROOT, capture_output=True, text=True)
        assert r.returncode == 0, f"pytest still failing: {r.stdout}"
        r = subprocess.run(["git", "log", "--oneline"], cwd=ROOT,
                           capture_output=True, text=True)
        assert "feat: grep_lines" in r.stdout, r.stdout
    step("S6 test+git in 7 daemon-side steps (L3 batch — 1 RPC)",
         s6_test_and_commit)

    print("\n✓ COMPLEX REAL-DEV DEMO PASSED — all 3 layers chosen by confidence")
    if _OWNED:
        try:
            s.close()
        except Exception:
            pass


if __name__ == "__main__":
    main()
