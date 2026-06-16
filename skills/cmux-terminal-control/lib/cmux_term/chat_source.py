"""Chat-stream data source for claude/codex CLI sessions.

Tails the structured transcript jsonl that claude/codex writes to disk and
exposes a clean event stream of {assistant_text, thinking, tool_use, user}.

Files watched:
  Claude: ~/.claude/projects/<encoded_cwd>/<session_id>.jsonl
  Codex:  ~/.codex/sessions/YYYY/MM/DD/rollout-*-<session_id>.jsonl

Read this layer when an agent session is claude/codex; it gives structured
data without OCR-ing the screen. Falls back to wait_for_text when the file
isn't writable / agent is something else.
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator, Literal, Optional


AgentKind = Literal["claude", "codex"]


@dataclass
class ChatEvent:
    """One structured event from the transcript."""
    kind: str  # "user" | "assistant_text" | "thinking" | "tool_use" | "tool_result" | "turn_end"
    text: str = ""
    tool_name: str = ""
    tool_input: dict = field(default_factory=dict)
    tool_id: str = ""
    raw: dict = field(default_factory=dict)


def encode_claude_project_dir(cwd: str) -> str:
    """Replicate claude's encoding: leading `/` → `-`, `/` → `-`, `.` kept."""
    if not cwd.startswith("/"):
        cwd = "/" + cwd
    return cwd.replace("/", "-")


def find_claude_transcript(session_id: str, cwd: Optional[str] = None) -> Optional[str]:
    """Locate the claude transcript file by session id (+ optional cwd)."""
    home = Path.home()
    proj_root = home / ".claude" / "projects"
    if cwd:
        candidate = proj_root / encode_claude_project_dir(cwd) / f"{session_id}.jsonl"
        if candidate.exists():
            return str(candidate)
    # Fallback: walk all project dirs
    if not proj_root.exists():
        return None
    for d in proj_root.iterdir():
        if not d.is_dir():
            continue
        candidate = d / f"{session_id}.jsonl"
        if candidate.exists():
            return str(candidate)
    return None


def find_codex_transcript(session_id: str) -> Optional[str]:
    """Locate codex rollout file by session id."""
    home = Path.home()
    root = home / ".codex" / "sessions"
    if not root.exists():
        return None
    needle = session_id.lower()
    for path in root.rglob("*.jsonl"):
        if needle in path.name.lower():
            return str(path)
    return None


def find_newest_claude_transcript(cwd: str) -> Optional[tuple[str, str]]:
    """Find the newest claude transcript in cwd's project dir.

    Returns (session_id, path) or None. Used when caller has a cwd
    but no session id (hook-bypassed claude).
    """
    home = Path.home()
    proj_dir = home / ".claude" / "projects" / encode_claude_project_dir(cwd)
    if not proj_dir.exists():
        return None
    newest = None
    newest_mtime = 0.0
    for f in proj_dir.glob("*.jsonl"):
        m = f.stat().st_mtime
        if m > newest_mtime:
            newest_mtime = m
            newest = f
    if newest is None:
        return None
    return (newest.stem, str(newest))


def parse_claude_line(d: dict) -> Iterator[ChatEvent]:
    """Yield events from one claude jsonl line."""
    t = d.get("type")
    if t == "user":
        msg = d.get("message", {})
        content = msg.get("content")
        if isinstance(content, str):
            yield ChatEvent(kind="user", text=content, raw=d)
        elif isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get("type") == "text":
                    yield ChatEvent(kind="user", text=c.get("text", ""), raw=d)
                elif isinstance(c, dict) and c.get("type") == "tool_result":
                    yield ChatEvent(
                        kind="tool_result",
                        tool_id=c.get("tool_use_id", ""),
                        text=str(c.get("content", "")),
                        raw=d,
                    )
    elif t == "assistant":
        msg = d.get("message", {})
        for c in msg.get("content", []):
            if not isinstance(c, dict):
                continue
            ct = c.get("type")
            if ct == "text":
                yield ChatEvent(kind="assistant_text", text=c.get("text", ""), raw=d)
            elif ct == "thinking":
                yield ChatEvent(kind="thinking", text=c.get("thinking", ""), raw=d)
            elif ct == "tool_use":
                yield ChatEvent(
                    kind="tool_use",
                    tool_name=c.get("name", ""),
                    tool_input=c.get("input", {}) or {},
                    tool_id=c.get("id", ""),
                    raw=d,
                )
        # End of an assistant turn — emit a synthetic event
        yield ChatEvent(kind="turn_end", raw=d)


def parse_codex_line(d: dict) -> Iterator[ChatEvent]:
    """Yield events from one codex rollout jsonl line."""
    t = d.get("type") or d.get("kind") or ""
    payload = d.get("payload") or d.get("message") or d
    if t in ("user_message", "user") or payload.get("role") == "user":
        text = payload.get("content") or payload.get("text") or ""
        if isinstance(text, list):
            text = "".join(p.get("text", "") for p in text if isinstance(p, dict))
        yield ChatEvent(kind="user", text=str(text), raw=d)
    elif t in ("assistant_message", "assistant", "message") or payload.get("role") == "assistant":
        content = payload.get("content") or payload.get("text") or ""
        if isinstance(content, str):
            yield ChatEvent(kind="assistant_text", text=content, raw=d)
        elif isinstance(content, list):
            for c in content:
                if isinstance(c, dict):
                    if c.get("type") == "text":
                        yield ChatEvent(kind="assistant_text", text=c.get("text", ""), raw=d)
                    elif c.get("type") in ("tool_use", "function_call"):
                        yield ChatEvent(
                            kind="tool_use",
                            tool_name=c.get("name", ""),
                            tool_input=c.get("input", {}) or c.get("arguments", {}) or {},
                            tool_id=c.get("id", ""),
                            raw=d,
                        )
        yield ChatEvent(kind="turn_end", raw=d)
    elif t in ("tool_call", "function_call"):
        yield ChatEvent(
            kind="tool_use",
            tool_name=payload.get("name", ""),
            tool_input=payload.get("arguments", {}) or payload.get("input", {}) or {},
            tool_id=payload.get("id", ""),
            raw=d,
        )


def parse_line(agent_kind: AgentKind, d: dict) -> Iterator[ChatEvent]:
    if agent_kind == "claude":
        yield from parse_claude_line(d)
    else:
        yield from parse_codex_line(d)


class ChatStream:
    """Tails a transcript file, emitting structured events.

    Usage:
        s = ChatStream(path="/path/to/transcript.jsonl", agent_kind="claude")
        s.replay_existing()              # one-shot scan of existing content
        for ev in s.poll(timeout=10):    # block-poll for new events
            ...
    """

    def __init__(self, path: str, agent_kind: AgentKind):
        self.path = path
        self.agent_kind: AgentKind = agent_kind
        self._offset = 0
        self._buf = b""
        self._inode: Optional[int] = None

    def _check_rotated(self) -> bool:
        try:
            st = os.stat(self.path)
        except FileNotFoundError:
            return False
        if self._inode is not None and st.st_ino != self._inode:
            self._offset = 0
            self._buf = b""
            self._inode = st.st_ino
            return True
        if self._inode is None:
            self._inode = st.st_ino
        # Truncated?
        if st.st_size < self._offset:
            self._offset = 0
            self._buf = b""
        return False

    def _read_new_lines(self) -> list[str]:
        try:
            with open(self.path, "rb") as f:
                f.seek(self._offset)
                chunk = f.read()
                self._offset = f.tell()
        except FileNotFoundError:
            return []
        self._buf += chunk
        if b"\n" not in self._buf:
            return []
        lines_bytes = self._buf.split(b"\n")
        # Last element after split is fragment after final newline
        self._buf = lines_bytes[-1]
        out = []
        for lb in lines_bytes[:-1]:
            if not lb.strip():
                continue
            try:
                out.append(lb.decode("utf-8"))
            except UnicodeDecodeError:
                continue
        return out

    def replay_existing(self) -> Iterator[ChatEvent]:
        """One-shot: read everything currently in the file."""
        self._check_rotated()
        for line in self._read_new_lines():
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            yield from parse_line(self.agent_kind, d)

    def poll(self, timeout: float = 10.0, interval: float = 0.05) -> Iterator[ChatEvent]:
        """Block up to `timeout` seconds, yielding events as they arrive.

        Returns when timeout expires (yielding nothing further). Does NOT
        yield until something new lands; pure tail mode. interval = poll
        period; default 50 ms.
        """
        deadline = time.time() + timeout
        while time.time() < deadline:
            self._check_rotated()
            lines = self._read_new_lines()
            if lines:
                for line in lines:
                    try:
                        d = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    yield from parse_line(self.agent_kind, d)
            else:
                time.sleep(interval)

    def wait_for(
        self,
        predicate,
        timeout: float = 30.0,
        interval: float = 0.05,
    ) -> Optional[ChatEvent]:
        """Block until `predicate(event)` returns True, or timeout. Returns the matching event or None."""
        # First check existing content
        for ev in self.replay_existing():
            if predicate(ev):
                return ev
        # Then tail
        for ev in self.poll(timeout=timeout, interval=interval):
            if predicate(ev):
                return ev
        return None


def open_stream(
    *,
    agent_kind: AgentKind,
    session_id: Optional[str] = None,
    cwd: Optional[str] = None,
) -> Optional[ChatStream]:
    """Locate transcript and return a ChatStream, or None if not found."""
    path = None
    if agent_kind == "claude" and session_id:
        path = find_claude_transcript(session_id, cwd=cwd)
    elif agent_kind == "claude" and cwd:
        result = find_newest_claude_transcript(cwd)
        if result:
            path = result[1]
    elif agent_kind == "codex" and session_id:
        path = find_codex_transcript(session_id)
    if not path:
        return None
    return ChatStream(path=path, agent_kind=agent_kind)
