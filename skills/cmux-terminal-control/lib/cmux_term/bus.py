"""cmux Agent Bus — multi-agent message bus over cmux's notification RPCs.

See docs/design/agent-bus.md for the full design. Quick summary:

  - Agents publish JSON envelopes via `cmux rpc notification.create`
    using title="agent.bus" + body='{"$bus":1,"from":...,"kind":...}'.
  - The cmux daemon stores them with kind=bus (no UI alert).
  - Dispatchers wait via `cmux rpc notification.wait kind=bus body_contains=...`,
    which is a single blocking RPC that returns when a matching
    message arrives (true push from the client's POV).

Roles:
  - Producer side: `publish_command(...)` returns the exact shell
    command an agent should run.
  - Consumer side: `AgentBus()` exposes wait / wait_any / wait_all /
    drain over the same daemon queue.

Bounds enforced daemon-side:
  - body ≤ 4096 bytes (use `artifacts: [path]` for big content)
  - validated envelope: $bus=1, from=[A-Za-z0-9_.:-]{1..64},
    kind ∈ {done, progress, needs_input, error, log, cancel, note, ack}
"""

import json
import os
import time
from typing import Iterable, List, Optional, Sequence, Union

from ._rpc import CmuxError, TimeoutError, rpc


BUS_VERSION = 1
BUS_TITLE = "agent.bus"
ALLOWED_KINDS = frozenset({
    "done", "progress", "needs_input", "error", "log",
    "cancel", "note", "ack",
})


# --------- envelope construction ---------


def make_envelope(*,
                  from_: str,
                  kind: str = "done",
                  to: Union[str, Sequence[str]] = "*",
                  ref: Optional[str] = None,
                  thread: Optional[str] = None,
                  summary: Optional[str] = None,
                  artifacts: Optional[Iterable[str]] = None,
                  extra: Optional[dict] = None) -> dict:
    """Build a bus envelope dict. Validates locally to fail fast."""
    if kind not in ALLOWED_KINDS:
        raise CmuxError(f"bus: unknown kind {kind!r}; allowed={sorted(ALLOWED_KINDS)}")
    if not from_ or not isinstance(from_, str) or len(from_) > 64:
        raise CmuxError(f"bus: invalid from={from_!r}")
    env: dict = {"$bus": BUS_VERSION, "from": from_, "kind": kind}
    if to != "*":
        env["to"] = list(to) if isinstance(to, (list, tuple)) else to
    if ref:
        env["ref"] = ref
    if thread:
        env["thread"] = thread
    if summary:
        env["summary"] = summary[:400]
    if artifacts:
        env["artifacts"] = list(artifacts)
    if extra:
        env["extra"] = extra
    return env


def publish_command(**kwargs) -> str:
    """Return the exact shell command a sub-agent should run to publish.

    Pass any kwargs accepted by `make_envelope`. Returns a string that
    can be embedded literally in an LLM prompt; contains no shell
    metacharacters that need extra escaping by the agent.

    The body JSON must start with {"$bus":1 — JSON dict ordering is
    insertion-ordered in Python 3.7+ and we built make_envelope to put
    $bus first.
    """
    env = make_envelope(**kwargs)
    # Insertion order produces $bus first, which the daemon's prefix
    # check requires. Compact, no trailing whitespace.
    body = json.dumps(env, separators=(",", ":"), ensure_ascii=False)
    if len(body.encode("utf-8")) > 4096:
        raise CmuxError(
            f"bus: envelope is {len(body.encode('utf-8'))} bytes "
            f"(>4096 cap). Move large content into artifacts paths."
        )
    rpc_args = json.dumps(
        {"title": BUS_TITLE, "body": body},
        separators=(",", ":"),
        ensure_ascii=False,
    )
    # Single-quote for shell. JSON has no single quotes by construction
    # (we use ensure_ascii=False but encode strings escape ' as it isn't
    # in JSON spec — JSON strings only escape ", \, control chars). So
    # plain single-quote wrap is safe.
    return f"cmux rpc notification.create '{rpc_args}'"


def publish_now(**kwargs) -> dict:
    """Same as publish_command but execute it directly via the cmux RPC.

    Used for in-process testing and for dispatcher-side broadcasts
    (e.g. dispatcher publishing a `note` to coordinate agents).
    Returns the daemon's create response (id, created_at, kind).
    """
    env = make_envelope(**kwargs)
    body = json.dumps(env, separators=(",", ":"), ensure_ascii=False)
    if len(body.encode("utf-8")) > 4096:
        raise CmuxError("bus: envelope >4096 bytes")
    return rpc("notification.create", {"title": BUS_TITLE, "body": body})


# --------- consumer ---------


class AgentBusMessage:
    """Parsed bus envelope. Lazy access to fields with sensible defaults."""

    def __init__(self, raw: dict):
        self.raw = raw
        try:
            self.payload: dict = json.loads(raw.get("body") or "{}")
        except json.JSONDecodeError:
            self.payload = {}

    @property
    def id(self) -> Optional[str]:
        return self.raw.get("id")

    @property
    def from_(self) -> str:
        return self.payload.get("from", "")

    @property
    def to(self) -> Union[str, list]:
        return self.payload.get("to", "*")

    @property
    def kind(self) -> str:
        return self.payload.get("kind", "")

    @property
    def ref(self) -> Optional[str]:
        return self.payload.get("ref")

    @property
    def thread(self) -> Optional[str]:
        return self.payload.get("thread") or self.payload.get("ref")

    @property
    def summary(self) -> str:
        return self.payload.get("summary", "")

    @property
    def artifacts(self) -> List[str]:
        return list(self.payload.get("artifacts") or [])

    @property
    def extra(self) -> dict:
        return self.payload.get("extra") or {}

    def addressed_to(self, recipient: str) -> bool:
        """True if this message is for `recipient` (or a broadcast)."""
        to = self.to
        if to == "*":
            return True
        if isinstance(to, list):
            return recipient in to
        return to == recipient

    def __repr__(self) -> str:
        return (f"<BusMsg from={self.from_!r} kind={self.kind!r} "
                f"to={self.to!r} ref={self.ref!r}>")


class AgentBus:
    """Dispatcher-side handle on the multi-agent bus.

    Stateless aside from a `_seen` set used to avoid re-delivering the
    same message across multiple wait_* calls in this process. Multiple
    AgentBus instances in the same process share daemon state but each
    tracks its own `_seen` independently — by design, multiple
    consumers can each receive the same message.
    """

    def __init__(self) -> None:
        self._seen: set = set()

    # ----- single-shot wait -----

    # Detected once per process: does this daemon know `kind="bus"`?
    _daemon_kind_filter_supported: Optional[bool] = None

    def wait(self, *,
             from_: Optional[str] = None,
             to: Optional[str] = None,
             kind: Optional[str] = None,
             ref: Optional[str] = None,
             timeout_ms: int = 600_000,
             dismiss: bool = True) -> AgentBusMessage:
        """Block until a matching bus message arrives.

        Filters AND-combine. The most selective filter is used as the
        daemon-side `body_contains` to maximize early skipping; the
        rest are re-checked client-side after JSON parse.

        `dismiss=True` (default) removes the matched notification from
        the daemon ring once we've consumed it, so it doesn't come back
        on subsequent waits. Set to False to keep it visible (rare —
        useful for "tee" patterns).
        """
        body_contains = self._daemon_filter(from_=from_, to=to, kind=kind, ref=ref)
        deadline = time.time() + timeout_ms / 1000.0
        while time.time() < deadline:
            chunk_ms = min(60_000, max(500, int((deadline - time.time()) * 1000)))
            try:
                params: dict = {"timeout_ms": chunk_ms}
                # Tag with kind=bus only if the daemon supports it.
                # Older daemons (without the bus patch) don't know
                # about kind filters and treat it as part of the
                # opaque params dict.
                if AgentBus._daemon_kind_filter_supported is not False:
                    params["kind"] = "bus"
                if body_contains:
                    params["body_contains"] = body_contains
                else:
                    # Force daemon to only consider bus-shaped bodies.
                    params["body_contains"] = '"$bus":1'
                n = rpc("notification.wait", params,
                        timeout=max(15, chunk_ms // 1000 + 5))
            except CmuxError as e:
                msg = str(e)
                if "timeout" in msg.lower():
                    if time.time() >= deadline:
                        break
                    continue
                # Daemon doesn't support kind="bus" filter (older build)?
                # Fall back to body_contains-only path.
                if "Unknown" in msg or "unknown_method" in msg:
                    raise
                # Other transport errors: brief sleep then retry
                time.sleep(0.2)
                continue
<<<<<<< HEAD
            nid = n.get("id")
            if nid in self._seen:
                # Already saw it; nudge daemon along.
                if nid:
                    try:
                        rpc("notification.dismiss", {"id": nid})
                    except CmuxError:
                        pass
                continue
            m = AgentBusMessage(n)
            self._seen.add(nid)
            if not self._matches_filters(m, from_=from_, to=to, kind=kind, ref=ref):
                # Non-matching: dismiss daemon-side so we don't keep
                # bumping into it.
                if nid:
                    try:
                        rpc("notification.dismiss", {"id": nid})
                    except CmuxError:
                        pass
                continue
            if dismiss and nid:
                try:
                    rpc("notification.dismiss", {"id": nid})
=======
            if n.get("id") in self._seen:
                continue
            m = AgentBusMessage(n)
            if not self._matches_filters(m, from_=from_, to=to, kind=kind, ref=ref):
                self._seen.add(m.id)
                continue
            self._seen.add(m.id)
            if dismiss and m.id:
                try:
                    rpc("notification.dismiss", {"id": m.id})
>>>>>>> d33b9b83c (feat(agent-bus): cmux-native multi-agent message bus)
                except CmuxError:
                    pass
            return m
        raise TimeoutError(
            f"AgentBus.wait(from={from_!r}, kind={kind!r}, "
            f"ref={ref!r}, to={to!r}): {timeout_ms}ms elapsed"
        )

    # ----- multi-agent select -----

    def wait_any(self, *, agents: Iterable[str],
                 kind: Optional[str] = "done",
                 timeout_ms: int = 600_000,
                 dismiss: bool = True) -> AgentBusMessage:
<<<<<<< HEAD
        """Return the first message from ANY of `agents` matching `kind`.

        Strategy: ALWAYS dismiss the message we just received (including
        non-matching ones) so the daemon's `notification.wait` doesn't
        keep returning the same head-of-queue entry on every iteration.
        Client-side `_seen` is just an extra guard.
        """
=======
        """Return the first message from ANY of `agents` matching `kind`."""
>>>>>>> d33b9b83c (feat(agent-bus): cmux-native multi-agent message bus)
        agents = list(agents)
        if not agents:
            raise CmuxError("wait_any: no agents specified")
        deadline = time.time() + timeout_ms / 1000.0
        body_contains = f'"kind":"{kind}"' if kind else None
        while time.time() < deadline:
            chunk_ms = min(60_000, max(500, int((deadline - time.time()) * 1000)))
            try:
                params: dict = {"kind": "bus", "timeout_ms": chunk_ms}
                if body_contains:
                    params["body_contains"] = body_contains
                n = rpc("notification.wait", params,
                        timeout=max(15, chunk_ms // 1000 + 5))
            except CmuxError as e:
                if "timeout" in str(e).lower():
                    continue
                raise
<<<<<<< HEAD
            nid = n.get("id")
            if nid in self._seen:
                # Already handled in this process — but daemon still
                # has it. Dismiss to advance daemon's view.
                if nid:
                    try:
                        rpc("notification.dismiss", {"id": nid})
                    except CmuxError:
                        pass
                continue
            m = AgentBusMessage(n)
            self._seen.add(nid)
            if m.from_ in agents and (kind is None or m.kind == kind):
                if dismiss and nid:
                    try:
                        rpc("notification.dismiss", {"id": nid})
                    except CmuxError:
                        pass
                return m
            # Non-matching: dismiss it daemon-side so subsequent waits
            # don't keep finding it again.
            if nid:
                try:
                    rpc("notification.dismiss", {"id": nid})
                except CmuxError:
                    pass
=======
            if n.get("id") in self._seen:
                continue
            m = AgentBusMessage(n)
            if m.from_ in agents and (kind is None or m.kind == kind):
                self._seen.add(m.id)
                if dismiss and m.id:
                    try:
                        rpc("notification.dismiss", {"id": m.id})
                    except CmuxError:
                        pass
                return m
            # Not for us; mark seen so we don't re-consider
            self._seen.add(m.id)
>>>>>>> d33b9b83c (feat(agent-bus): cmux-native multi-agent message bus)
        raise TimeoutError(f"wait_any({agents!r}, kind={kind!r}): {timeout_ms}ms elapsed")

    def wait_all(self, *, agents: Iterable[str],
                 kind: Optional[str] = "done",
                 timeout_ms: int = 1_800_000,
                 dismiss: bool = True) -> List[AgentBusMessage]:
        """Wait for every listed agent to post a matching message.

        Returns messages in completion order. Raises TimeoutError if
        any agent fails to report within the deadline.
        """
        pending = set(agents)
        deadline = time.time() + timeout_ms / 1000.0
        out: List[AgentBusMessage] = []
        while pending and time.time() < deadline:
            remain_ms = max(500, int((deadline - time.time()) * 1000))
            m = self.wait_any(agents=pending, kind=kind,
                              timeout_ms=remain_ms, dismiss=dismiss)
            out.append(m)
            pending.discard(m.from_)
        if pending:
            raise TimeoutError(
                f"wait_all: still pending {sorted(pending)!r} after {timeout_ms}ms"
            )
        return out

    # ----- non-blocking drain -----

    def drain(self, *,
              from_: Optional[str] = None,
              kind: Optional[str] = None,
              dismiss: bool = True) -> List[AgentBusMessage]:
        """Pull every currently-buffered bus message matching the
        filter. Non-blocking. Useful for end-of-task cleanup or to
        reconcile after a missed wait."""
        listing = rpc("notification.list", {"kind": "bus"}).get("notifications", [])
        out: List[AgentBusMessage] = []
        for n in listing:
            if n.get("id") in self._seen:
                continue
            m = AgentBusMessage(n)
            if from_ and m.from_ != from_:
                continue
            if kind and m.kind != kind:
                continue
            self._seen.add(m.id)
            if dismiss and m.id:
                try:
                    rpc("notification.dismiss", {"id": m.id})
                except CmuxError:
                    pass
            out.append(m)
        return out

    # ----- helpers -----

    @staticmethod
    def _daemon_filter(*, from_, to, kind, ref) -> Optional[str]:
        """Pick the most-selective JSON substring as a daemon-side hint.

        Order of preference: ref (most unique) > from > to > kind.
        """
        if ref:
            return f'"ref":"{ref}"'
        if from_:
            return f'"from":"{from_}"'
        if to:
            return f'"to":"{to}"'
        if kind:
            return f'"kind":"{kind}"'
        return None

    @staticmethod
    def _matches_filters(m: AgentBusMessage, *,
                         from_, to, kind, ref) -> bool:
        if from_ and m.from_ != from_:
            return False
        if kind and m.kind != kind:
            return False
        if ref and m.ref != ref:
            return False
        if to and not m.addressed_to(to):
            return False
        return True


# --------- prompt-fragment helpers ---------


def render_protocol_instructions(*,
                                 agent: str,
                                 ref: str,
                                 done_summary_hint: str = "1 sentence",
                                 progress: bool = False,
                                 to: str = "dispatcher") -> str:
    """Prose to append to a sub-agent prompt teaching it to publish.

    The agent runs the printed `cmux rpc ...` command verbatim from
    its Bash tool when it finishes (or hits `needs_input` etc.).
    """
    done_cmd = publish_command(
        from_=agent, to=to, kind="done", ref=ref,
        summary="<REPLACE-WITH-1-LINE-SUMMARY>",
    )
    parts = [
        "When you finish the task (after self-verification), publish a "
        "completion message to the cmux agent bus by running this Bash "
        "command verbatim, replacing <REPLACE-WITH-1-LINE-SUMMARY> with "
        f"a {done_summary_hint} summary describing what you did:",
        "  " + done_cmd,
        "",
        "Big results MUST go through file paths. Add an `artifacts` array "
        "to the body listing absolute paths instead of inlining text.",
    ]
    if progress:
        progress_cmd = publish_command(
            from_=agent, to=to, kind="progress", ref=ref,
            summary="<short status>",
        )
        parts += [
            "",
            "Optional: while working, you may publish progress updates:",
            "  " + progress_cmd,
        ]
    needs_input_cmd = publish_command(
        from_=agent, to=to, kind="needs_input", ref=ref,
        summary="<your question>",
    )
    parts += [
        "",
        "If you need clarification, publish a `needs_input` message:",
        "  " + needs_input_cmd,
        "",
        f"Always set `from` to {agent!r}, `ref` to {ref!r}, and `$bus` to 1 "
        "exactly as the example shows. Do not invent extra top-level keys.",
    ]
    return "\n".join(parts)


# --------- env helpers (for sub-agents that need their identity) ---------


def export_identity_env(agent: str, ref: str) -> dict:
    """Returns env vars an agent can use to know its own bus identity.

    Pass these via `env=` when spawning the agent's process. Useful
    when the same agent CLI is run multiple times in the same workspace.
    """
    return {
        "CMUX_BUS_AGENT": agent,
        "CMUX_BUS_REF": ref,
        "CMUX_BUS_VERSION": str(BUS_VERSION),
    }


def my_identity() -> dict:
    """Used inside an agent process to read the identity passed via env."""
    return {
        "agent": os.environ.get("CMUX_BUS_AGENT", ""),
        "ref":   os.environ.get("CMUX_BUS_REF", ""),
    }
