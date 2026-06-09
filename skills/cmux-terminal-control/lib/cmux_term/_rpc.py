"""Low-level cmux RPC transport. Not user-facing."""

import json
import subprocess


class CmuxError(Exception):
    pass


class TimeoutError(CmuxError):
    """Raised when a verified op fails to observe expected screen state."""


def rpc(method: str, params: dict, *, timeout: int = 15) -> dict:
    proc = subprocess.run(
        ["cmux", "rpc", method, json.dumps(params)],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    out = proc.stdout
    if proc.returncode != 0 and not out.strip():
        raise CmuxError(f"{method} failed: {proc.stderr.strip()}")
    if not out.strip():
        raise CmuxError(f"{method} returned empty body")
    if out.strip().startswith("Error:"):
        raise CmuxError(out.strip())
    try:
        return json.loads(out, strict=False)
    except json.JSONDecodeError as e:
        raise CmuxError(f"{method} returned non-JSON: {out[:200]}") from e
