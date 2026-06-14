"""cmux_term — 3-layer API for driving cmux terminal panels from an LLM.

LLM picks the layer based on confidence and step granularity:

  Layer 1: raw    — no verify, fastest, ~1 RPC per op
  Layer 2: atomic — single-step verify, ~3 RPC per op (hash + send + wait)
  Layer 3: flow   — composite verified flows (type_line, vim_edit, run_script)
                    + batch (run_steps) packs N steps into ONE RPC

Decision guide:
  - Confidence >= 95%, repetitive: raw.send_* + a single trailing
    `atomic.expect(...)` to confirm the whole batch landed.
  - Confidence < 90%, branchy / interactive TUI: atomic.press / atomic.type
    on each step, fail-fast on dropped keys.
  - Multiple high-confidence shell commands: flow.run_lines or
    batch.run_steps([send_line(...), wait_text(...)]) — daemon-side fail-fast.
  - Open-edit-save in vim: flow.vim_edit(path, content=...) (composite).
  - One-shot script: flow.run_script(multiline_bash) (composite).

Public re-exports so callers can `from cmux_term import Surface, raw, atomic`:
"""

from . import agent, atomic, batch, bus, flow, raw, team
from ._rpc import CmuxError, TimeoutError, rpc
from .agent import AgentFleet, AgentSession, AiderAgent, ClaudeAgent, CodexAgent
from .bus import AgentBus, AgentBusMessage
from .flow import Surface
from .team import Plan, RunResult, Task, TaskOutcome, Team, TeamRunError

__all__ = [
    "Surface",
    "TimeoutError",
    "CmuxError",
    "raw",
    "atomic",
    "batch",
    "bus",
    "flow",
    "agent",
    "rpc",
    "AgentSession",
    "AgentFleet",
    "ClaudeAgent",
    "CodexAgent",
    "AiderAgent",
    "AgentBus",
    "AgentBusMessage",
    "team",
    "Plan",
    "Task",
    "TaskOutcome",
    "Team",
    "TeamRunError",
    "RunResult",
]
