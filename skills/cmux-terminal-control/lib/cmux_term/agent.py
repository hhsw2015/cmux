"""Layer 4 — schedule Agent CLIs (Claude / Codex / Gemini / aider).

This is the highest-leverage layer. You don't drive an agent's keyboard;
you delegate a task to another LLM and verify what it produced.

Two interaction modes — LLM picks based on task complexity:

1. **Interactive mode** (default) — back-and-forth chat.
   For mid-complexity work where you want to steer in real time:
   give feedback after every turn, change direction, answer the
   agent's clarifying questions.

       a = ClaudeAgent.spawn(s, cwd="/tmp/project")
       a.delegate("draft a CLI for csv → json")
       a.wait_for_done(sentinel)
       a.chat("good. now add a --pretty flag")
       a.wait_for_done(sentinel2)

2. **Goal mode** (optional, for long autonomous runs) — set /goal,
   walk away, come back when it's done. Use when the task is heavy
   and well-specified and you want token cost on YOUR side to drop
   to ~zero polling cost. Heavy refactors, "keep extending until
   coverage ≥ 90%", "fix every TODO in this file".

       a.set_goal("get the test suite to 90%+ coverage, then exit")
       a.wait_for_text("Goal complete", timeout_ms=30 * 60_000)

   Note: goal mode is FLEXIBLE, not a freeze. You can:
     - send `chat()` mid-run to steer without changing the goal,
     - call `set_goal()` again to OVERWRITE the active goal with a
       new one (the agent picks up the new objective from the next
       turn onward),
     - call `clear_goal()` to drop autonomy and return to plain chat.
   Goal is the autonomy *floor*, not a ceiling.

Pick interactive when the task is fluid and you want flexibility.
Pick goal when the task is heavy and you want autonomy. Mix freely:
set a goal, then steer with chat() if needed.

Token economics:
  - One send_text carries the whole prompt (~one RPC).
  - Polling is `screen_hash` (~100B) cached; we only fetch text when
    the hash changes OR we want to look for a completion marker.
  - Verification is reading the artifact on disk (no terminal IO).
"""

import os
import time
import uuid
from typing import Optional

from ._rpc import CmuxError, TimeoutError, rpc
from . import atomic, bus as _bus, flow, raw


# ---------- common helpers used across all agent CLIs ----------


def _send_prompt(surface_id: str, prompt: str) -> None:
    """Send a multi-line prompt to an agent CLI and submit.

    Most agent CLIs accept multi-line input via bracketed paste —
    which is what `send_text` does. We push the whole prompt as one
    text blob, then a single Enter to submit.
    """
    raw.send_text(surface_id, prompt)
    # Most CLIs need a tiny settle before Enter so the input editor
    # registers the paste boundary.
    time.sleep(0.15)
    raw.send_key(surface_id, "enter")


def _wait_settled(surface_id: str, *, settle_ms: int = 800,
                  deadline_ms: int = 5000) -> None:
    """Wait until the agent stops streaming output.

    Agent CLIs stream tokens, so wait_for_idle with a larger settle
    window separates 'between-thoughts pauses' from 'fully done'.
    """
    rpc(
        "surface.wait_for_idle",
        {
            "surface_id": surface_id,
            "settle_ms": settle_ms,
            "deadline_ms": deadline_ms,
        },
    )


# ---------- base class ----------


class AgentSession:
    """An agent CLI running inside a cmux surface.

    Subclasses customize the launch command and the completion markers
    they look for. The base class provides the spawn/delegate/wait/verify
    protocol that callers actually use.
    """

    LAUNCH_CMD: str = ""           # set by subclass
    READY_MARKERS: tuple = ()      # substrings printed when prompt is ready
    DONE_MARKERS: tuple = ()       # substrings printed when a turn finishes
    GOAL_COMMAND: Optional[str] = None  # e.g. "/goal "

    def __init__(self, surface_id: str, *, cwd: Optional[str] = None,
                 agent_id: Optional[str] = None):
        self.surface_id = surface_id
        self.cwd = cwd
        # Stable identity for bus messages — multi-agent fleets use this
        # to route notifications back to the right session.
        self.agent_id = agent_id or f"agent_{uuid.uuid4().hex[:8]}"
        self._spawned = False

    # ----- factories -----

    @classmethod
    def spawn(cls, surface, *, cwd: Optional[str] = None,
              extra_args: str = "",
              ready_timeout_ms: int = 30_000) -> "AgentSession":
        """Launch the agent CLI inside `surface` (a Surface or surface_id).

        `surface` may be either a `flow.Surface` or a raw surface_id str.
        We `cd` to `cwd` first if given, then run the launch command and
        wait for one of READY_MARKERS to appear.

        Multi-step shell input (cd → launch) is chained with `&&` to
        avoid back-to-back send_text concatenation under zsh+highlighting.
        """
        sid = surface.id if hasattr(surface, "id") else surface
        self = cls(sid, cwd=cwd)
        cmd = cls.LAUNCH_CMD
        if extra_args:
            cmd = f"{cmd} {extra_args}"
        full = f"cd {cwd} && {cmd}" if cwd else cmd
        raw.send_text(sid, full + "\n")
        # Wait for any ready marker
        if cls.READY_MARKERS:
            self.wait_for_any(cls.READY_MARKERS, timeout_ms=ready_timeout_ms)
        else:
            _wait_settled(sid, settle_ms=1200, deadline_ms=ready_timeout_ms)
        self._spawned = True
        return self

    # ----- delegation -----

    def delegate(self, prompt: str, *, notify: str = "bus") -> str:
        """Hand a task to the agent. Returns a token for wait_for_done().

        Notification strategies (push, not poll — save tokens):

          - "bus" (default, RECOMMENDED) — agent publishes to the cmux
            agent bus when done. Structured JSON envelope: dispatcher
            blocks on a daemon-side wait filtered by token, then
            verifies artifacts on disk. See docs/design/agent-bus.md.

          - "cmux" — legacy free-form notification. Same shape as
            "bus" but without the typed envelope. Useful against
            daemons that don't yet have the bus path.

          - "cmux_native" — don't ask the agent to do anything. We
            listen for cmux's built-in "Claude is waiting for your
            input" notification.

          - "file" — agent writes /tmp/cmux-agent-done-<token>.

          - "screen" — agent prints a unique string. Pays screen-
            scrape tokens; only viable for short tasks.

          - None / "off" — no instruction; you verify externally.
        """
        token = uuid.uuid4().hex[:12].upper()

        if notify == "bus":
            instruction = "\n\n" + _bus.render_protocol_instructions(
                agent=self.agent_id, ref=token,
            )
            _send_prompt(self.surface_id, prompt.rstrip() + instruction)
            return token

        if notify == "cmux":
            sentinel = f"CMXDONE_{token}"
            instruction = (
                f"\n\nWhen the entire task is finished AND verified, "
                f"signal completion by running this exact shell command "
                f"(via your Bash tool):\n"
                f"  cmux rpc notification.create "
                f"'{{\"title\":\"agent_done\",\"body\":\"{sentinel}\"}}'\n"
                f"Run it once, after everything is done. Do not print "
                f"this token back to me — just deliver the notification."
            )
            _send_prompt(self.surface_id, prompt.rstrip() + instruction)
            return sentinel

        if notify == "cmux_native":
            _send_prompt(self.surface_id, prompt)
            return ""  # caller must use wait_for_done(notify="cmux_native")

        if notify == "file":
            sentinel_path = f"/tmp/cmux-agent-done-{token}"
            instruction = (
                f"\n\nWhen the entire task is finished AND verified, "
                f"signal completion by running this exact shell command:\n"
                f"  : > {sentinel_path}\n"
                f"Run it via your Bash tool, not as a chat reply. Do not "
                f"print this path back to me — just create the file."
            )
            _send_prompt(self.surface_id, prompt.rstrip() + instruction)
            return sentinel_path

        if notify == "screen":
            half_a = f"CMXDONE_{token[:5]}"
            half_b = f"_{token[5:11]}"
            sentinel = f"{half_a}{half_b}"
            instruction = (
                f"\n\nWhen the entire task is finished and verified, "
                f"print on its own line the literal concatenation of "
                f"these two strings (no space between):\n"
                f"  part1: {half_a}\n"
                f"  part2: {half_b}\n"
                f"Print only the concatenated value, not the labels."
            )
            _send_prompt(self.surface_id, prompt.rstrip() + instruction)
            return sentinel

        if notify in (None, "off"):
            _send_prompt(self.surface_id, prompt)
            return ""

        raise ValueError(
            f"notify must be 'cmux' / 'cmux_native' / 'file' / 'screen' / None, "
            f"got {notify!r}"
        )

    def chat(self, message: str, *, notify: str = "cmux") -> str:
        """Send a follow-up message in interactive mode.

        Same as delegate() but conceptually a continuation of an
        ongoing conversation rather than a fresh task. Returns a
        token like delegate() does.
        """
        return self.delegate(message, notify=notify)

    # ----- goal mode (optional, for long-running autonomous tasks) -----

    def set_goal(self, goal_text: str) -> None:
        """OPTIONAL: install a long-running goal so the agent runs
        autonomously across many turns.

        Use ONLY when the task is heavy AND well-specified AND you don't
        need to steer mid-flight. For interactive/exploratory work,
        prefer plain `delegate()` + `chat()`. /goal is the autonomy
        knob, not the default.

        For agents that support /goal (Claude Code, Codex CLI), this
        installs a session-scoped objective the agent will keep
        pursuing. Token cost on OUR side drops to near-zero polling.
        """
        if not self.GOAL_COMMAND:
            raise CmuxError(
                f"{type(self).__name__} doesn't support a goal command — "
                "use delegate() with append_sentinel=True instead"
            )
        raw.send_text(self.surface_id, self.GOAL_COMMAND + goal_text)
        time.sleep(0.2)
        raw.send_key(self.surface_id, "enter")

    def update_goal(self, goal_text: str) -> None:
        """Mid-run: replace the active goal with a new one.

        For Claude Code / Codex CLI, calling /goal again overwrites the
        previous one — semantically equivalent to set_goal() but reads
        more clearly at call sites where you're steering, not seeding.
        """
        self.set_goal(goal_text)

    def clear_goal(self) -> None:
        """Drop the active goal so the agent stops running autonomously
        and returns to plain chat-driven mode."""
        if not self.GOAL_COMMAND:
            return
        raw.send_text(self.surface_id, "/goal clear")
        time.sleep(0.15)
        raw.send_key(self.surface_id, "enter")

    # ----- waiting / observation -----

    def wait_for_text(self, substring: str, *, timeout_ms: int = 600_000) -> None:
        try:
            r = rpc(
                "surface.wait_for_text",
                {"surface_id": self.surface_id, "substring": substring,
                 "timeout_ms": timeout_ms},
            )
        except CmuxError as e:
            if "timeout" in str(e).lower():
                raise TimeoutError(
                    f"wait_for_text({substring!r}): {timeout_ms}ms elapsed"
                ) from e
            raise
        if not (r.get("matched") or r.get("matched_line")):
            raise TimeoutError(
                f"wait_for_text({substring!r}): not seen in {timeout_ms}ms"
            )

    def wait_for_any(self, substrings, *, timeout_ms: int = 60_000) -> str:
        """Wait until ANY of `substrings` appears. Returns the one matched.

        Polls screen_hash cheaply; only fetches text when something changed.
        Tolerates transient `not_found` (e.g. surface just created and
        not yet wired up).
        """
        deadline = time.time() + timeout_ms / 1000.0
        last_hash = None
        while time.time() < deadline:
            try:
                h = raw.screen_hash(self.surface_id)
            except CmuxError:
                time.sleep(0.4)
                continue
            if h != last_hash:
                last_hash = h
                try:
                    txt = raw.screen_text(self.surface_id)
                except CmuxError:
                    time.sleep(0.2)
                    continue
                for sub in substrings:
                    if sub in txt:
                        return sub
            time.sleep(0.4)
        raise TimeoutError(
            f"wait_for_any({list(substrings)!r}): {timeout_ms}ms elapsed"
        )

    def wait_for_done(self, token: Optional[str] = None, *,
                      notify: str = "bus",
                      timeout_ms: int = 600_000,
                      check_disk=None,
                      poll_interval_ms: int = 1500) -> None:
        """Block until the agent reports completion. PUSH, not POLL —
        we wait on cmux's notification queue rather than scraping the
        screen, so token cost stays flat regardless of task length.

        notify must match what was passed to delegate():

          - "cmux" — wait for a notification whose body contains
            `token`. The agent fires it via `cmux rpc
            notification.create` when finished. We dismiss the
            matching notification so it doesn't re-fire later.

          - "cmux_native" — wait for ANY cmux notification newer than
            our wait-start. Useful when the agent itself doesn't know
            the token; we trust cmux's built-in "agent waiting for
            input" notification.

          - "file" — wait for `token` (a path) to exist. OS file
            watch is push-y on Linux/macOS; we poll once per
            `poll_interval_ms` as a portable fallback (still cheap
            since it's a stat() with no terminal IO).

          - "screen" — wait for `token` substring on screen. Pays
            screen-scrape tokens; only acceptable for short tasks.

        `check_disk` (optional path or list) must also exist before
        we return — protects against agent fired-and-died-before-fsync.

        Why push beats poll: a 30-minute autonomous task with poll-
        every-second = 1800 reads × 100B hash = 180 KB. With cmux
        notify, we make ONE RPC after we get pushed.
        """
        deadline = time.time() + timeout_ms / 1000.0
        disk_paths = []
        if check_disk:
            disk_paths = [check_disk] if isinstance(check_disk, str) else list(check_disk)

        if notify == "bus":
            if not token:
                raise CmuxError("wait_for_done(notify='bus'): need token from delegate()")
            bus_inst = _bus.AgentBus()
            remain_ms = max(500, int((deadline - time.time()) * 1000))
            bus_inst.wait(
                from_=self.agent_id, kind="done", ref=token,
                timeout_ms=remain_ms,
            )
        elif notify == "cmux":
            if not token:
                raise CmuxError("wait_for_done(notify='cmux'): need token from delegate()")
            self._wait_cmux_notification(token, deadline, poll_interval_ms)
        elif notify == "cmux_native":
            self._wait_cmux_notification(None, deadline, poll_interval_ms,
                                         since=time.time())
        elif notify == "file":
            if not token:
                raise CmuxError("wait_for_done(notify='file'): need path from delegate()")
            while time.time() < deadline:
                if os.path.exists(token):
                    break
                time.sleep(poll_interval_ms / 1000.0)
            else:
                raise TimeoutError(f"wait_for_done(file): {token!r} not created")
        elif notify == "screen":
            if not token:
                raise CmuxError("wait_for_done(notify='screen'): need sentinel from delegate()")
            remain_ms = max(500, int((deadline - time.time()) * 1000))
            self.wait_for_text(token, timeout_ms=remain_ms)
        elif notify in (None, "off"):
            if not disk_paths and not self.DONE_MARKERS:
                raise CmuxError("wait_for_done: nothing to wait on")
            if self.DONE_MARKERS and not disk_paths:
                remain_ms = max(500, int((deadline - time.time()) * 1000))
                self.wait_for_any(self.DONE_MARKERS, timeout_ms=remain_ms)
        else:
            raise ValueError(f"unknown notify={notify!r}")

        for path in disk_paths:
            while time.time() < deadline:
                if os.path.exists(path):
                    break
                time.sleep(0.3)
            else:
                raise TimeoutError(
                    f"wait_for_done: artifact {path!r} not created"
                )

    def _wait_cmux_notification(self, body_token: Optional[str],
                                deadline: float,
                                poll_interval_ms: int,
                                since: Optional[float] = None) -> dict:
        """Wait for a cmux notification, optionally matching `body_token`.

        Tries the daemon-side `notification.wait` blocking RPC first
        (true single-RPC wait, no client-side polling). Falls back to
        client-side `notification.list` polling on older daemon
        builds without that endpoint. Either way the notification is
        dismissed before we return so it doesn't re-fire later.
        """
        timeout_ms = max(500, int((deadline - time.time()) * 1000))
        # Try blocking wait first.
        try:
            params: dict = {"timeout_ms": timeout_ms}
            if body_token:
                params["body_contains"] = body_token
            n = rpc("notification.wait", params,
                    timeout=max(15, timeout_ms // 1000 + 5))
            nid = n.get("id")
            if nid:
                try:
                    rpc("notification.dismiss", {"id": nid})
                except CmuxError:
                    pass
            return n
        except CmuxError as e:
            # If the daemon doesn't know about notification.wait, fall
            # through to polling. Other errors propagate.
            if "unknown_method" not in str(e) and "Method" not in str(e):
                # Real error or genuine timeout — pop back into the
                # polling loop only on first-class transport issues.
                if "timeout" in str(e).lower():
                    raise TimeoutError(
                        f"wait_for_done(cmux): no notification "
                        f"{'matching ' + repr(body_token) if body_token else 'received'}"
                    ) from e
                # Other errors → fall back to polling

        seen_ids: set = set()
        if since is not None:
            try:
                existing = rpc("notification.list", {}).get("notifications", [])
                seen_ids = {n.get("id") for n in existing if n.get("id")}
            except CmuxError:
                pass
        while time.time() < deadline:
            try:
                listing = rpc("notification.list", {}).get("notifications", [])
            except CmuxError:
                time.sleep(poll_interval_ms / 1000.0)
                continue
            for n in listing:
                nid = n.get("id")
                if nid in seen_ids:
                    continue
                if body_token is None or body_token in (n.get("body") or ""):
                    if nid:
                        try:
                            rpc("notification.dismiss", {"id": nid})
                        except CmuxError:
                            pass
                    return n
            time.sleep(poll_interval_ms / 1000.0)
        raise TimeoutError(
            f"wait_for_done(cmux): no notification "
            f"{'matching ' + repr(body_token) if body_token else 'received'}"
        )

    def wait_idle_long(self, *, settle_ms: int = 5_000,
                       deadline_ms: int = 600_000) -> None:
        """Wait until the agent stops streaming for `settle_ms`.

        Cheap fallback when there's no usable sentinel/marker — agents
        only go quiet when they're done or stuck on a prompt.
        """
        rpc(
            "surface.wait_for_idle",
            {"surface_id": self.surface_id,
             "settle_ms": settle_ms, "deadline_ms": deadline_ms},
        )

    # ----- escape hatches -----

    def screen_tail(self, last_rows: int = 12) -> str:
        """Cheap read of the bottom of the agent screen — useful for
        inspecting state without burning a full screen_text."""
        return rpc(
            "surface.screen_region",
            {"surface_id": self.surface_id, "last_rows": last_rows},
        ).get("text", "")

    def interrupt(self) -> None:
        """Send Ctrl+C to break out of an in-flight agent action."""
        raw.send_key(self.surface_id, "ctrl+c")

    def exit(self) -> None:
        """Try graceful exit, fall back to Ctrl+C."""
        raw.send_text(self.surface_id, "/exit\n")
        time.sleep(0.5)
        # Some CLIs use /quit
        raw.send_text(self.surface_id, "/quit\n")
        time.sleep(0.3)
        raw.send_key(self.surface_id, "ctrl+c")


# ---------- concrete CLIs ----------


class ClaudeAgent(AgentSession):
    """Claude Code CLI.

    Default launch passes --dangerously-skip-permissions so the agent
    can read/write files and run shell commands without per-action
    confirmation. ONLY use this in a sandboxed cwd you control.
    """

    LAUNCH_CMD = "claude --dangerously-skip-permissions"
    READY_MARKERS = (
        # Wrapping-tolerant substrings. Claude Code shows these once
        # ready; partial matches are intentional — the bottom status
        # line `⏵⏵ bypass permissions on (shift+tab to cycle)` wraps
        # at narrow panel widths so we match the unique mid-string
        # `bypass permissions` without the trailing `on`.
        "bypass permissions",
        "? for shortcuts",
        "for shortcuts",
        "Welcome back",
    )
    # First-time trust prompt for unfamiliar workdir. We auto-confirm.
    TRUST_PROMPT_MARKER = "Yes, I trust this folder"
    DONE_MARKERS = ()
    GOAL_COMMAND = "/goal "

    @classmethod
    def spawn(cls, surface, *, cwd=None, extra_args="",
              direction: str = "right",
              initial_divider_position: Optional[float] = None,
              ready_timeout_ms: int = 60_000) -> "ClaudeAgent":
        """Spawn Claude in a fresh terminal panel.

        Two-step: (1) `surface.split` opens a new panel with the right
        `working_directory`. We DO NOT pass `initial_command` because
        when claude exits, cmux closes the panel — and a misconfigured
        claude can exit instantly. (2) Send the claude command via
        `send_text` with a trailing newline. The panel's first input
        is sent to a freshly-spawned shell that has no syntax-highlight
        plugins yet, so the simple send_text + \\n submission works
        reliably.
        """
        cmd = cls.LAUNCH_CMD
        if extra_args:
            cmd = f"{cmd} {extra_args}"
        parent_sid = surface.id if hasattr(surface, "id") else surface
        params = {
            "surface_id": parent_sid,
            "direction": direction,
            "type": "terminal",
        }
        if cwd:
            params["working_directory"] = cwd
        if initial_divider_position is not None:
            params["initial_divider_position"] = float(initial_divider_position)
        result = rpc("surface.split", params)
        sid = result["surface_id"]
        # Settle so the new surface fully wires up before we poll/send.
        time.sleep(1.5)
        # Launch claude — single send_text + newline.
        raw.send_text(sid, cmd + "\n")
        self = cls(sid, cwd=cwd)
        # Wait for either the trust prompt OR a ready marker.
        wait_targets = list(cls.READY_MARKERS) + [cls.TRUST_PROMPT_MARKER]
        seen = self.wait_for_any(wait_targets, timeout_ms=ready_timeout_ms)
        if seen == cls.TRUST_PROMPT_MARKER:
            # Auto-confirm trust ("1" + Enter selects "Yes")
            time.sleep(0.3)
            raw.send_text(sid, "1")
            time.sleep(0.2)
            raw.send_key(sid, "enter")
            self.wait_for_any(cls.READY_MARKERS, timeout_ms=ready_timeout_ms)
        self._spawned = True
        return self


class CodexAgent(AgentSession):
    """OpenAI Codex CLI."""

    LAUNCH_CMD = "codex"
    READY_MARKERS = (
        "▌",         # codex prompt cursor
        "send a message",
        "Codex",
    )
    DONE_MARKERS = ()
    GOAL_COMMAND = "/goal "


class AiderAgent(AgentSession):
    """aider — non-goal, single-turn-at-a-time. Use delegate() with sentinel."""

    LAUNCH_CMD = "aider --no-auto-commits --yes-always"
    READY_MARKERS = ("aider>", "architect>")
    DONE_MARKERS = ()
    GOAL_COMMAND = None


# ---------- multi-agent dispatcher ----------


class AgentFleet:
    """Manage multiple Agent sessions concurrently.

    Pattern:
        fleet = AgentFleet()
        a1 = fleet.add(ClaudeAgent.spawn(parent, cwd="/tmp/p1"))
        a2 = fleet.add(ClaudeAgent.spawn(parent, cwd="/tmp/p2"))
        t1 = a1.delegate("...", notify="cmux")
        t2 = a2.delegate("...", notify="cmux")
        fleet.track(a1, t1)
        fleet.track(a2, t2)
        # First-completed-wins: get the agent that finishes first.
        winner, payload = fleet.wait_any(timeout_ms=600_000)
        # Or wait for ALL to complete:
        results = fleet.wait_all(timeout_ms=600_000)

    The dispatcher's context cost stays flat regardless of fleet size:
    each `wait_any` is a single blocking RPC against the daemon's
    notification queue, filtered by body token.
    """

    def __init__(self):
        self.agents: dict = {}        # agent → token

    def add(self, agent: AgentSession) -> AgentSession:
        self.agents[agent] = None
        return agent

    def track(self, agent: AgentSession, token: str) -> None:
        if agent not in self.agents:
            self.add(agent)
        self.agents[agent] = token

    def wait_any(self, *, timeout_ms: int = 600_000) -> tuple:
        """Return (agent, notification_dict) for the first agent to
        finish. Removes that agent's token; remaining agents stay
        tracked so you can wait_any again."""
        deadline = time.time() + timeout_ms / 1000.0
        pending = [(ag, tok) for ag, tok in self.agents.items() if tok]
        if not pending:
            raise CmuxError("AgentFleet.wait_any: no tracked tokens")
        # Strategy: poll notification.list once per cycle and check
        # all tokens. One RPC per ~1.5s regardless of fleet size.
        while time.time() < deadline:
            try:
                listing = rpc("notification.list", {}).get("notifications", [])
            except CmuxError:
                time.sleep(0.5)
                continue
            for n in listing:
                body = n.get("body") or ""
                for ag, tok in pending:
                    if tok and tok in body:
                        nid = n.get("id")
                        if nid:
                            try:
                                rpc("notification.dismiss", {"id": nid})
                            except CmuxError:
                                pass
                        self.agents[ag] = None
                        return (ag, n)
            time.sleep(1.0)
        raise TimeoutError(f"AgentFleet.wait_any: {timeout_ms}ms elapsed")

    def wait_all(self, *, timeout_ms: int = 600_000) -> list:
        """Wait for every tracked agent to finish. Returns list of
        (agent, notification_dict) tuples in completion order."""
        deadline_total = time.time() + timeout_ms / 1000.0
        results: list = []
        while any(tok for tok in self.agents.values()):
            remaining_ms = max(500, int((deadline_total - time.time()) * 1000))
            results.append(self.wait_any(timeout_ms=remaining_ms))
        return results

    def shutdown(self) -> None:
        """Best-effort: exit + close every panel in the fleet."""
        for ag in list(self.agents.keys()):
            try:
                ag.exit()
            except Exception:
                pass
