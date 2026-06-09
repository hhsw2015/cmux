"""Layer 3 — composite flows. Built on atomic + raw.

Each method ties together multiple ops with end-state verification.
Use for: shell command exec, TUI launch/edit/quit, sentinel-bounce
ready-checks. The Surface class is the main entry point — it owns
a surface_id and dispatches to raw/atomic/batch as needed.
"""

import time
import uuid
from typing import Callable, Iterable, List, Optional

from ._rpc import CmuxError, TimeoutError, rpc
from . import atomic, raw
from . import batch as _batch


class Surface:
    """A cmux surface (panel) you can drive with verified primitives.

    Layered API surface:
      - .raw.*         layer 1 (no verify)
      - .press/.type   layer 2 (single-step verify)
      - .type_line, .launch, .vim_edit, .run_script, .run_steps  layer 3
    """

    def __init__(self, surface_id: str):
        self.id = surface_id

    # ------------- factories -------------

    @classmethod
    def from_focused_or_split(cls, *, direction: str = "right") -> "Surface":
        cls._cleanup_right_panels()
        listing = rpc("surface.list", {"workspace_id": "workspace:1"})
        focused = next(
            (s["id"] for s in listing["surfaces"] if s.get("focused")), None
        )
        if not focused:
            raise CmuxError("no focused surface")
        result = rpc("surface.split",
                     {"surface_id": focused, "direction": direction})
        new_id = result["surface_id"]
        rpc("surface.focus", {"surface_id": new_id})
        time.sleep(1.5)
        return cls(new_id)

    @classmethod
    def from_id(cls, surface_id: str) -> "Surface":
        return cls(surface_id)

    @staticmethod
    def _cleanup_right_panels() -> None:
        try:
            listing = rpc("surface.list", {"workspace_id": "workspace:1"})
        except CmuxError:
            return
        for s in listing.get("surfaces", []):
            if s.get("frame", {}).get("x", 0) > 314.5:
                try:
                    rpc("surface.close", {"surface_id": s["id"]})
                except CmuxError:
                    pass
        time.sleep(0.5)

    # ------------- layer 1 / raw passthrough -------------

    def send_key_raw(self, key: str) -> None:
        raw.send_key(self.id, key)

    def send_text_raw(self, text: str) -> None:
        raw.send_text(self.id, text)

    def send_keys_raw(self, keys: Iterable[str]) -> None:
        raw.send_keys(self.id, keys)

    # ------------- reads -------------

    def screen(self) -> str:
        return raw.screen_text(self.id)

    def hash(self) -> str:
        return raw.screen_hash(self.id)

    def kind(self) -> str:
        return raw.tui_probe(self.id).get("kind", "unknown")

    def cursor(self) -> tuple:
        d = raw.tui_probe(self.id)
        return (d.get("cursor_row", -1), d.get("cursor_col", -1))

    def last_lines(self, n: int = 3) -> list:
        d = raw.tui_probe(self.id)
        return d.get("last_lines", [])[-n:]

    # ------------- layer 2 / verified atomic -------------

    def press(self, key: str, *, timeout_ms: int = 1500) -> None:
        atomic.press(self.id, key, timeout_ms=timeout_ms)

    def type(self, text: str, *, char_by_char: bool = False,
             timeout_ms: int = 2500) -> None:
        atomic.type_text(self.id, text, char_by_char=char_by_char,
                         timeout_ms=timeout_ms)

    def expect(self, substring: str, *, timeout_ms: int = 5000) -> None:
        atomic.expect(self.id, substring, timeout_ms=timeout_ms)

    def expect_kind(self, kinds, *, timeout_ms: int = 5000) -> str:
        return atomic.expect_kind(self.id, kinds, timeout_ms=timeout_ms)

    def expect_cursor(self, *, row=None, col=None, timeout_ms=2000):
        return atomic.expect_cursor(self.id, row=row, col=col,
                                    timeout_ms=timeout_ms)

    def expect_screen_change(self, prev_hash: str, *, timeout_ms=1500) -> str:
        return atomic.expect_screen_change(self.id, prev_hash,
                                           timeout_ms=timeout_ms)

    def wait_idle(self, settle_ms=300, deadline_ms=2500) -> None:
        atomic.wait_idle(self.id, settle_ms, deadline_ms)

    # ------------- layer 3 / composite flows -------------

    def wait_ready(self, *, timeout_ms: int = 8000) -> None:
        sentinel = f"CMUX_READY_{uuid.uuid4().hex[:8]}"
        raw.send_text(self.id, f"echo {sentinel}\n")
        self.expect(sentinel, timeout_ms=timeout_ms)
        self.wait_idle()

    def assert_back_at_shell(self, *, timeout_ms: int = 3000) -> None:
        marker = f"CMUX_BACK_{uuid.uuid4().hex[:6]}"
        raw.send_text(self.id, f"echo {marker}\n")
        self.expect(marker, timeout_ms=timeout_ms)

    def type_line(self, line: str, *, expect: Optional[str] = None,
                  timeout_ms: int = 5000) -> None:
        """Submit a shell command, wait for prompt to come back via sentinel.

        Sentinel-bounce pattern: type cmd + Enter, wait_idle, then echo a
        unique marker and wait for it. The marker only appears once the
        shell is back at a prompt and ran the echo.
        """
        self.type(line)
        self.press("enter")
        self.wait_idle(300, 4000)
        sentinel = f"CMUX_LINE_{uuid.uuid4().hex[:8]}"
        time.sleep(0.15)
        raw.send_text(self.id, f"echo {sentinel}")
        time.sleep(0.05)
        raw.send_key(self.id, "enter")
        self.expect(sentinel, timeout_ms=max(timeout_ms, 5000))
        self.wait_idle()
        if expect:
            self.expect(expect, timeout_ms=timeout_ms)

    def run_lines(self, lines: Iterable[str], *,
                  bounce_each: bool = False,
                  expect_after: Optional[str] = None,
                  timeout_ms: int = 30000) -> None:
        """Submit a batch of shell commands.

        bounce_each=False (default) — fast path: send all commands separated
        by `&&` joined? No, easier: send each followed by raw Enter, then
        sentinel-bounce ONCE at the end. Cheap & fast for high-confidence
        chains. If any command hangs, the trailing sentinel waits and
        eventually times out.

        bounce_each=True — verifies each line returns to a prompt before
        sending the next. Slower; use for unreliable commands.
        """
        lines = list(lines)
        if bounce_each:
            for ln in lines:
                self.type_line(ln, timeout_ms=timeout_ms)
        else:
            for ln in lines:
                raw.send_text(self.id, ln)
                raw.send_key(self.id, "enter")
                time.sleep(0.05)
            # one sentinel after the whole batch
            sentinel = f"CMUX_BATCH_{uuid.uuid4().hex[:8]}"
            time.sleep(0.2)
            raw.send_text(self.id, f"echo {sentinel}")
            raw.send_key(self.id, "enter")
            self.expect(sentinel, timeout_ms=timeout_ms)
            self.wait_idle()
        if expect_after:
            self.expect(expect_after, timeout_ms=timeout_ms)

    def run_script(self, script: str, *, shell: str = "bash",
                   expect_after: Optional[str] = None,
                   timeout_ms: int = 60000) -> None:
        """Write a multiline script to a tempfile (locally on disk) and run
        it in one shell invocation.

        We write the file directly with Python rather than streaming a
        heredoc through `send_text` — embedded `\\n` in `send_text` goes
        through bracketed paste, where multi-line shell input gets
        buffered as one logical line. That breaks heredocs reliably.

        cmux is local-only; the panel sees the same filesystem as us.
        For a future remote target, override this method or write your
        own helper.
        """
        import os as _os
        path = f"/tmp/cmux_run_{uuid.uuid4().hex[:8]}.sh"
        with open(path, "w") as f:
            f.write(script.rstrip("\n") + "\n")
        _os.chmod(path, 0o755)
        sentinel = f"CMUX_SCRIPT_{uuid.uuid4().hex[:8]}"
        # one shell invocation; `; echo SENT_$?` carries the exit code on
        # the same logical line so we always get a sentinel even on err.
        raw.send_text(self.id, f"{shell} {path}; echo {sentinel}_$?")
        raw.send_key(self.id, "enter")
        self.expect(sentinel, timeout_ms=timeout_ms)
        self.wait_idle()
        if expect_after:
            self.expect(expect_after, timeout_ms=timeout_ms)

    def launch(self, cmd: str, *, expect: str,
               timeout_ms: int = 5000) -> None:
        """Launch a TUI program. Caller must pass `expect=` substring that
        appears once the TUI rendered (file name in vim status line, etc.).
        Does NOT sentinel-bounce because the TUI would consume it."""
        self.type(cmd)
        self.press("enter")
        self.expect(expect, timeout_ms=timeout_ms)
        self.wait_idle()

    def exec_ex(self, command: str, *, timeout_ms: int = 3000) -> None:
        """Run a vim ex command (`:command`). Caller is in normal mode."""
        if not command.startswith(":"):
            command = ":" + command
        prev = self.hash()
        raw.send_text(self.id, command + "\n")
        rpc(
            "surface.wait_for_screen_change",
            {"surface_id": self.id, "prev_hash": prev,
             "timeout_ms": timeout_ms},
        )
        self.wait_idle()

    def vim_edit(self, path: str, *, content: Optional[str] = None,
                 substitute: Optional[tuple] = None,
                 vi_bin: str = "/usr/bin/vi -u NONE -N",
                 verify_basename: bool = True) -> None:
        """Open file in vi, perform an edit, save.

        - content=str: enter insert mode, type content (newlines as Enter), wq.
        - substitute=(pattern, repl): :%s#pat#repl#g + wq.
        Exactly one of content/substitute must be given.
        """
        import os.path as op
        basename = op.basename(path)
        self.launch(f"{vi_bin} {path}",
                    expect=basename if verify_basename else " ")
        self.wait_idle(400, 2500)
        if content is not None and substitute is not None:
            raise ValueError("vim_edit: pass either content OR substitute, not both")
        if content is not None:
            self.press("i")
            self.expect("INSERT")
            lines = content.split("\n")
            for i, ln in enumerate(lines):
                if ln:
                    self.type(ln)
                if i < len(lines) - 1:
                    self.press("enter")
            self.press("escape")
        elif substitute is not None:
            pat, repl = substitute
            self.exec_ex(f":%s#{pat}#{repl}#g")
        else:
            raise ValueError("vim_edit: need content= or substitute=")
        self.exec_ex(":wq")
        self.wait_idle(400, 3000)

    # ------------- batch / multi-step in one RPC -------------

    def run_steps(self, steps: List[dict], *,
                  stop_on_error: bool = True,
                  tail_rows: int = 5,
                  timeout_ms: int = 30000) -> dict:
        """Run a sequence of {send,wait_text,wait_idle,...} steps in ONE RPC.

        Daemon-side fail-fast. Cheapest way to do a multi-step flow when
        you trust the steps will succeed. See `cmux_term.batch.steps_*`
        builders for ergonomic step construction.
        """
        return _batch.run_steps(self.id, steps, stop_on_error=stop_on_error,
                                tail_rows=tail_rows, timeout_ms=timeout_ms)

    # ------------- recovery -------------

    def reset(self) -> None:
        """Best-effort: leave any TUI, exit any heredoc, return to shell."""
        # Drop out of any heredoc/line-continuation: ctrl+c repeatedly,
        # which also breaks any partial input the shell is buffering.
        for _ in range(3):
            raw.send_key(self.id, "ctrl+c")
            time.sleep(0.1)
        # Leave any vim/less mode
        for _ in range(2):
            raw.send_key(self.id, "escape")
            time.sleep(0.05)
        raw.send_text(self.id, ":q!\n")
        time.sleep(0.2)
        raw.send_key(self.id, "ctrl+c")
        time.sleep(0.1)
        raw.send_text(self.id, "\nclear\n")
        self.wait_idle(300, 2000)

    def close(self) -> None:
        try:
            rpc("surface.close", {"surface_id": self.id})
        except CmuxError:
            pass
