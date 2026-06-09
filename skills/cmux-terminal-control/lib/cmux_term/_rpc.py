"""Low-level cmux RPC transport. Not user-facing."""

import json
import subprocess


class CmuxError(Exception):
    pass


class TimeoutError(CmuxError):
    """Raised when a verified op fails to observe expected screen state."""


def rpc(method: str, params: dict, *, timeout: int = 15) -> dict:
    import os as _os
    env = dict(_os.environ)
    # Tell the cmux CLI to wait at least as long as our subprocess
    # timeout — otherwise long blocking RPCs (notification.wait) hit
    # the CLI's default 15s response timeout before the daemon even
    # has a chance to reply.
    env["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = str(max(15, timeout))
    proc = subprocess.run(
        ["cmux", "rpc", method, json.dumps(params)],
        capture_output=True,
        text=True,
        timeout=timeout,
        env=env,
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
