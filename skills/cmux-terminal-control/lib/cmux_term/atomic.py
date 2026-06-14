"""Layer 2 — atomic verified primitives.

Each call sends ONE thing and verifies it observably landed before
returning. If the screen does not change in `timeout_ms`, raises
`TimeoutError`.

Use when: you don't have full confidence the keystroke will land
(unfamiliar TUI, prompt may be slow, want fail-fast on dropped keys).

Cost: ~1 hash + 1 wait_for_screen_change per op. For long stretches
of high-confidence input prefer Layer 1 (`raw.*`) + a trailing
`expect`.
"""

import time
from typing import Iterable, List, Union

from ._rpc import CmuxError, TimeoutError, rpc
from . import raw


# Canonical key names accepted by surface.send_key. Keep in sync with
# pendingKeyEvent in Packages/CmuxTerminal/.../TerminalSurface+Input.swift.
# LLMs can import this to validate a key name before sending instead of
# guessing (was the alias `arrow_up` or `up`? both work — listed here).
KEY_NAMES = (
    "ctrl-c", "ctrl+c", "sigint",
    "ctrl-d", "ctrl+d", "eof",
    "ctrl-f", "ctrl+f",
    "ctrl-z", "ctrl+z", "sigtstp",
    "ctrl-\\", "ctrl+\\", "sigquit",
    "enter", "return",
    "tab",
    "escape", "esc",
    "backspace",
    "up", "arrow_up", "arrowup",
    "down", "arrow_down", "arrowdown",
    "left", "arrow_left", "arrowleft",
    "right", "arrow_right", "arrowright",
    "shift+tab", "shift-tab", "backtab",
    "home", "end",
    "delete", "del", "forward_delete",
    "pageup", "page_up",
    "pagedown", "page_down",
    # f1-f24, plus "ctrl+<letter>", "shift+<letter>", "alt+<letter>", "cmd+<letter>"
    # combos are also accepted via the modifier+base parser.
)


def snapshot(surface_id: str) -> dict:
    """Combined screen read: text, cursor, dimensions, state_seq, and
    inverse-video highlights in one RPC. Highlights mark TUI selection
    (active menu item, vim cursor block, selected pane) so the LLM can
    read which option is active without text/cursor heuristics.

    Returns a dict with keys: text, cursor ({row,col} or None), rows,
    columns, state_seq, highlights (list of {row,col,length,text}).
    """
    return rpc("surface.snapshot", {"surface_id": surface_id})


def paste_lines(surface_id: str, lines: Iterable[str], *,
                line_terminator: str = "\n",
                expect_after: str | None = None,
                timeout_ms: int = 4000) -> None:
    """Send N lines as one bracketed text block. Each line is followed
    by `line_terminator` (default `\\n`); the terminal sees a single
    multi-line input the same way a human paste does. One verify at
    the end (optionally on `expect_after`), not one per line.

    Use for: REPL multi-line scripts, here-docs, vim `:put` content.
    Avoid for: TUI menus (use atomic.press), shell command sequences
    (use flow.run_lines so each command's exit is checked).
    """
    blob = line_terminator.join(lines)
    if not blob.endswith(line_terminator):
        blob += line_terminator
    if expect_after is not None:
        prev = raw.screen_hash(surface_id)
        rpc("surface.send_text", {"surface_id": surface_id, "text": blob})
        r = rpc(
            "surface.wait_for_text",
            {"surface_id": surface_id, "substring": expect_after,
             "timeout_ms": timeout_ms},
        )
        if not (r.get("matched") or r.get("matched_line")):
            raise TimeoutError(
                f"paste_lines: '{expect_after}' not seen in {timeout_ms}ms"
            )
        return
    prev = raw.screen_hash(surface_id)
    rpc("surface.send_text", {"surface_id": surface_id, "text": blob})
    r = rpc(
        "surface.wait_for_screen_change",
        {"surface_id": surface_id, "prev_hash": prev, "timeout_ms": timeout_ms},
    )
    if not r.get("changed"):
        raise TimeoutError(f"paste_lines: no screen change in {timeout_ms}ms")


def press(surface_id: str, key: str, *, timeout_ms: int = 1500) -> None:
    """Send a named key. Raise if screen doesn't change."""
    prev = raw.screen_hash(surface_id)
    rpc("surface.send_key", {"surface_id": surface_id, "key": key})
    r = rpc(
        "surface.wait_for_screen_change",
        {"surface_id": surface_id, "prev_hash": prev, "timeout_ms": timeout_ms},
    )
    if not r.get("changed"):
        raise TimeoutError(f"press({key!r}): no screen change in {timeout_ms}ms")


def type_text(surface_id: str, text: str, *,
              char_by_char: bool = False, timeout_ms: int = 2500) -> None:
    """Send text. Default: one verify per call. char_by_char verifies each char."""
    if char_by_char:
        for c in text:
            _send_text_one(surface_id, c, timeout_ms)
        return
    _send_text_one(surface_id, text, timeout_ms)


def _send_text_one(surface_id: str, text: str, timeout_ms: int) -> None:
    prev = raw.screen_hash(surface_id)
    rpc("surface.send_text", {"surface_id": surface_id, "text": text})
    r = rpc(
        "surface.wait_for_screen_change",
        {"surface_id": surface_id, "prev_hash": prev, "timeout_ms": timeout_ms},
    )
    if not r.get("changed"):
        raise TimeoutError(f"type_text({text!r:.40}): no screen change")


def expect(surface_id: str, substring: str, *, timeout_ms: int = 5000) -> None:
    try:
        r = rpc(
            "surface.wait_for_text",
            {"surface_id": surface_id, "substring": substring,
             "timeout_ms": timeout_ms},
        )
    except CmuxError as e:
        if "timeout" in str(e).lower():
            raise TimeoutError(
                f"expect({substring!r}): not seen in {timeout_ms}ms"
            ) from e
        raise
    if not (r.get("matched") or r.get("matched_line")):
        raise TimeoutError(f"expect({substring!r}): not seen in {timeout_ms}ms")


def expect_kind(surface_id: str, kinds: Union[str, Iterable[str]], *,
                timeout_ms: int = 5000) -> str:
    if isinstance(kinds, str):
        kinds = [kinds]
    kinds = list(kinds)
    deadline = time.time() + timeout_ms / 1000.0
    last = None
    while time.time() < deadline:
        last = raw.tui_probe(surface_id).get("kind")
        if last in kinds:
            return last
        time.sleep(0.1)
    raise TimeoutError(f"expect_kind({kinds!r}): last={last!r}")


def expect_screen_change(surface_id: str, prev_hash: str, *,
                         timeout_ms: int = 1500) -> str:
    r = rpc(
        "surface.wait_for_screen_change",
        {"surface_id": surface_id, "prev_hash": prev_hash,
         "timeout_ms": timeout_ms},
    )
    if not r.get("changed"):
        raise TimeoutError("expect_screen_change: no change")
    return r["hash"]


def wait_idle(surface_id: str, settle_ms: int = 300,
              deadline_ms: int = 2500) -> None:
    rpc(
        "surface.wait_for_idle",
        {"surface_id": surface_id, "settle_ms": settle_ms,
         "deadline_ms": deadline_ms},
    )


def expect_cursor(surface_id: str, *, row: int = None, col: int = None,
                  timeout_ms: int = 2000) -> tuple:
    """Wait until cursor reaches (row, col). Either coord may be None to ignore."""
    p = {"surface_id": surface_id, "timeout_ms": timeout_ms}
    if row is not None:
        p["row"] = row
    if col is not None:
        p["col"] = col
    r = rpc("surface.wait_for_cursor", p)
    if not r.get("matched"):
        cur = (r.get("cursor_row", -1), r.get("cursor_col", -1))
        raise TimeoutError(
            f"expect_cursor(row={row}, col={col}): last={cur} in {timeout_ms}ms"
        )
    return (r.get("cursor_row", -1), r.get("cursor_col", -1))
