"""Batch executor — wraps `surface.expect` daemon-side multi-step.

When you have a sequence of high-confidence steps, `run_steps` packs
them into ONE round trip. Daemon stops on first failure (default) and
returns {completed, total, steps[], tail, error?}.

Step shapes (each step is one of):
    {"send": "ls\n"}                    — send_text
    {"send_key": "enter"}               — send_key
    {"wait_text": "$ ", "timeout_ms": 3000}
    {"wait_idle": {"settle_ms": 300, "deadline_ms": 3000}}
    {"sleep_ms": 200}

Builders below produce these shapes ergonomically.
"""

from typing import List, Optional

from ._rpc import TimeoutError, rpc


def run_steps(surface_id: str, steps: List[dict], *,
              stop_on_error: bool = True,
              tail_rows: int = 5,
              timeout_ms: int = 30000,
              raise_on_step_error: bool = True) -> dict:
    """Execute steps in one daemon-side RPC.

    raise_on_step_error=True (default): any step failure raises
    `TimeoutError` with details. Set False to just return the result
    dict including .error.
    """
    r = rpc(
        "surface.expect",
        {
            "surface_id": surface_id,
            "steps": steps,
            "stop_on_error": stop_on_error,
            "tail_rows": tail_rows,
        },
        timeout=max(15, int(timeout_ms / 1000) + 5),
    )
    if raise_on_step_error and r.get("error"):
        err = r["error"]
        completed = r.get("completed", 0)
        total = r.get("total", len(steps))
        tail = r.get("tail", "")[-200:]
        raise TimeoutError(
            f"run_steps: step #{err.get('index', '?')} failed "
            f"({completed}/{total}): {err.get('message')}\ntail: {tail!r}"
        )
    return r


# -------- step builders --------

def send(text: str) -> dict:
    return {"send": text}


def send_line(text: str) -> dict:
    """Send a single shell command line.

    NOTE: returns ONE step that includes a trailing \\n. For chains of
    commands you almost always want `send_line_steps()` instead — that
    helper expands to text + Enter + small wait, which is necessary
    because the shell's input buffer otherwise concatenates back-to-back
    `send_line` calls into a single line.
    """
    return {"send": text + "\n"}


def send_line_steps(text: str, *, wait_after_ms: int = 250) -> list:
    """Expand into [send_text, send_key(enter), sleep_ms] for chained
    commands. Use this in `run_steps` when stacking multiple commands
    without an explicit `wait_text` between them — the small sleep gives
    the shell time to consume the Enter and emit a fresh prompt before
    the next command starts streaming in.
    """
    return [
        {"send": text},
        {"send_key": "enter"},
        {"sleep_ms": wait_after_ms},
    ]


def lines(*texts: str, wait_after_ms: int = 80) -> list:
    """Flatten multiple shell command lines into a step list."""
    out: list = []
    for t in texts:
        out.extend(send_line_steps(t, wait_after_ms=wait_after_ms))
    return out


def send_key(key: str) -> dict:
    return {"send_key": key}


def wait_text(substring: str, *, timeout_ms: int = 5000) -> dict:
    return {"wait_text": substring, "timeout_ms": timeout_ms}


def wait_idle(settle_ms: int = 300, deadline_ms: int = 3000) -> dict:
    return {"wait_idle": {"settle_ms": settle_ms, "deadline_ms": deadline_ms}}


def sleep_ms(ms: int) -> dict:
    return {"sleep_ms": ms}


# -------- common composites --------

def shell_cmd(cmd: str, *, expect: Optional[str] = None,
              timeout_ms: int = 5000) -> List[dict]:
    """Build steps for: type cmd + Enter, optionally wait for expected output."""
    out = [send_line(cmd)]
    if expect:
        out.append(wait_text(expect, timeout_ms=timeout_ms))
    else:
        out.append(wait_idle(300, deadline_ms=min(timeout_ms, 5000)))
    return out


def shell_chain(cmds: List[str], *, final_expect: Optional[str] = None,
                final_timeout_ms: int = 8000) -> List[dict]:
    """Multiple shell commands back to back, one final wait."""
    steps: List[dict] = []
    for c in cmds:
        steps.append(send_line(c))
        steps.append(sleep_ms(50))
    if final_expect:
        steps.append(wait_text(final_expect, timeout_ms=final_timeout_ms))
    else:
        steps.append(wait_idle(400, deadline_ms=final_timeout_ms))
    return steps
