"""Layer 1 — raw RPC. NO verification. Fast. LLM owns correctness.

Use when: you have very high confidence (>=95%) all keystrokes will land,
e.g. typing into a quiet shell prompt you just verified is responsive,
or entering a long pre-known string into vim insert mode.

Pair raw ops with a single trailing `atomic.expect(...)` (or
`flow.assert_back_at_shell()`) at the end of the batch — that single
read confirms the whole batch landed.

If a raw op silently drops, you will only notice at the trailing check.
That is the trade: cheap & fast vs fail-fast. For low-confidence work,
prefer `atomic.*`.
"""

from typing import Iterable

from ._rpc import rpc


def send_key(surface_id: str, key: str) -> None:
    rpc("surface.send_key", {"surface_id": surface_id, "key": key})


def send_text(surface_id: str, text: str) -> None:
    rpc("surface.send_text", {"surface_id": surface_id, "text": text})


def send_keys(surface_id: str, keys: Iterable[str]) -> None:
    """Send a sequence of named keys with no per-key verification.

    Useful for arrow-key navigation in pickers, F-key shortcuts, etc.
    """
    for k in keys:
        rpc("surface.send_key", {"surface_id": surface_id, "key": k})


def send_chunks(surface_id: str, chunks: Iterable[str]) -> None:
    """Send multiple text chunks back-to-back. No verification."""
    for c in chunks:
        rpc("surface.send_text", {"surface_id": surface_id, "text": c})


def screen_text(surface_id: str) -> str:
    return rpc("surface.screen_text", {"surface_id": surface_id})["text"]


def screen_hash(surface_id: str) -> str:
    return rpc("surface.screen_hash", {"surface_id": surface_id})["hash"]


def screen_region(surface_id: str, *, last_rows: int = None,
                  first_rows: int = None) -> str:
    p: dict = {"surface_id": surface_id}
    if last_rows is not None:
        p["last_rows"] = last_rows
    if first_rows is not None:
        p["first_rows"] = first_rows
    return rpc("surface.screen_region", p)["text"]


def tui_probe(surface_id: str) -> dict:
    return rpc("surface.tui_probe", {"surface_id": surface_id})
