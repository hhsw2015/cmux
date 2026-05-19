#!/usr/bin/env python3
"""Wire-protocol smoke tests for the cmux <-> herdr-cmux JSON-RPC.

Spawns a herdr-cmux daemon in a temp HOME, talks to its API socket
directly (one line per request, like the cmux Swift code does), and
verifies every RPC cmux relies on:

  ping
  workspace.create / list / get / rename / close
  layout.snapshot
  events.subscribe (workspace.created)

Skipped (rc=0 with stdout note) when herdr-cmux isn't on PATH.

Runnable locally:
  python3 tests/test_herdr_wire_protocol.py

CI: not run yet -- adding a step would require building the
hhsw2015/herdr fork on the runner first.
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import uuid


def find_herdr_cmux() -> str | None:
    explicit = os.environ.get("HERDR_CMUX_BIN")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit
    on_path = shutil.which("herdr-cmux")
    if on_path:
        return on_path
    user_install = os.path.expanduser("~/.local/bin/herdr-cmux")
    if os.path.exists(user_install) and os.access(user_install, os.X_OK):
        return user_install
    return None


def request(socket_path: str, method: str, params: dict, timeout: float = 5.0) -> dict:
    """One-shot JSON-RPC: open UDS, send single line, read reply line, close."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(socket_path)
    payload = {
        "id": str(uuid.uuid4()),
        "method": method,
        "params": params,
    }
    sock.sendall((json.dumps(payload) + "\n").encode("utf-8"))
    buffer = b""
    while not buffer.endswith(b"\n"):
        chunk = sock.recv(4096)
        if not chunk:
            break
        buffer += chunk
    sock.close()
    return json.loads(buffer.decode("utf-8"))


class HerdrWireProtocolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = find_herdr_cmux()
        if not cls.binary:
            raise unittest.SkipTest("herdr-cmux not found on PATH or HERDR_CMUX_BIN")
        # AF_UNIX paths are capped at 104 bytes on macOS (sun_path).
        # /var/folders tmpdir + nested .config/herdr/sessions/<name>/herdr.sock
        # blows past it, so put the test home under /tmp where the prefix
        # is short enough to leave headroom.
        cls.tmp_home = tempfile.mkdtemp(prefix="cmh-", dir="/tmp")
        cls.session = "wireproto"
        cls.env = {**os.environ, "HOME": cls.tmp_home, "XDG_CONFIG_HOME": cls.tmp_home + "/.config"}
        cls.socket_path = os.path.join(
            cls.tmp_home, ".config", "herdr", "sessions", cls.session, "herdr.sock"
        )
        cls.daemon = subprocess.Popen(
            [cls.binary, "--session", cls.session, "server"],
            env=cls.env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        for _ in range(50):
            if os.path.exists(cls.socket_path):
                return
            time.sleep(0.1)
        cls.daemon.terminate()
        raise RuntimeError(f"herdr-cmux daemon socket never appeared at {cls.socket_path}")

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, "daemon") and cls.daemon:
            cls.daemon.terminate()
            try:
                cls.daemon.wait(timeout=3)
            except subprocess.TimeoutExpired:
                cls.daemon.kill()
        if hasattr(cls, "tmp_home"):
            shutil.rmtree(cls.tmp_home, ignore_errors=True)

    def test_ping(self):
        resp = request(self.socket_path, "ping", {})
        self.assertIn("result", resp, msg=f"ping reply missing result: {resp}")
        # Reply shape: { result: { type: "pong", version, protocol } }
        self.assertEqual(resp["result"].get("type"), "pong")
        self.assertIn("version", resp["result"])
        self.assertIn("protocol", resp["result"])

    def test_workspace_create_list_get_rename_close(self):
        # create
        resp = request(
            self.socket_path,
            "workspace.create",
            {"focus": False, "label": "wire-original"},
        )
        result = resp.get("result", {})
        ws = result.get("workspace", {})
        ws_id = ws.get("workspace_id")
        self.assertIsNotNone(ws_id, msg=f"workspace.create no id: {resp}")
        self.assertEqual(ws.get("label"), "wire-original")
        # active_tab_id may not be present in workspace.create; verify via get below.

        # list
        resp = request(self.socket_path, "workspace.list", {})
        listed_ids = [w.get("workspace_id") for w in resp.get("result", {}).get("workspaces", [])]
        self.assertIn(ws_id, listed_ids)

        # rename
        request(self.socket_path, "workspace.rename", {"workspace_id": ws_id, "label": "wire-renamed"})
        resp = request(self.socket_path, "workspace.get", {"workspace_id": ws_id})
        self.assertEqual(resp.get("result", {}).get("workspace", {}).get("label"), "wire-renamed")

        # close
        request(self.socket_path, "workspace.close", {"workspace_id": ws_id})
        resp = request(self.socket_path, "workspace.list", {})
        listed_ids = [w.get("workspace_id") for w in resp.get("result", {}).get("workspaces", [])]
        self.assertNotIn(ws_id, listed_ids, msg="workspace.close did not remove from list")

    def test_layout_snapshot(self):
        resp = request(
            self.socket_path,
            "workspace.create",
            {"focus": True, "label": "wire-layout"},
        )
        ws = resp.get("result", {}).get("workspace", {})
        ws_id = ws.get("workspace_id")

        # Pull active_tab_id from workspace.get (the create reply may not include it)
        get_resp = request(self.socket_path, "workspace.get", {"workspace_id": ws_id})
        tab_id = get_resp.get("result", {}).get("workspace", {}).get("active_tab_id")
        self.assertIsNotNone(tab_id, msg=f"workspace.get had no active_tab_id: {get_resp}")

        snap = request(
            self.socket_path,
            "layout.snapshot",
            {"workspace_id": ws_id, "tab_id": tab_id},
        )
        self.assertIn("result", snap)
        # Reply shape: { result: { type: "layout_snapshot", tree: { root: {...} } } }
        tree = snap["result"].get("tree", {})
        self.assertIn("root", tree, msg=f"layout.snapshot tree missing root: {snap}")

        # cleanup
        request(self.socket_path, "workspace.close", {"workspace_id": ws_id})

    def test_pane_split_set_ratio_close(self):
        """pane.split → layout becomes a horizontal split → pane.set_split_ratio
        moves the divider → pane.close drops back to a single pane."""
        # Create workspace + pull active tab + initial pane.
        ws = request(
            self.socket_path,
            "workspace.create",
            {"focus": True, "label": "wire-split"},
        )["result"]["workspace"]
        ws_id = ws["workspace_id"]
        get_resp = request(self.socket_path, "workspace.get", {"workspace_id": ws_id})
        tab_id = get_resp["result"]["workspace"]["active_tab_id"]
        snap = request(
            self.socket_path,
            "layout.snapshot",
            {"workspace_id": ws_id, "tab_id": tab_id},
        )
        first_pane_id = snap["result"]["tree"]["root"]["pane_id"]

        # Split right (horizontal split, new pane on the right).
        split_resp = request(
            self.socket_path,
            "pane.split",
            {"target_pane_id": first_pane_id, "direction": "right", "focus": False},
        )
        new_pane_id = split_resp["result"]["pane"]["pane_id"]

        # Confirm layout is now a split with two panes.
        snap2 = request(
            self.socket_path,
            "layout.snapshot",
            {"workspace_id": ws_id, "tab_id": tab_id},
        )
        root = snap2["result"]["tree"]["root"]
        self.assertEqual(root.get("kind"), "split", msg=f"expected split root: {root}")
        self.assertIn(root.get("first", {}).get("pane_id"), (first_pane_id, new_pane_id))
        self.assertIn(root.get("second", {}).get("pane_id"), (first_pane_id, new_pane_id))

        # Move the divider via pane.set_split_ratio (path = [] targets the root split).
        request(
            self.socket_path,
            "pane.set_split_ratio",
            {"workspace_id": ws_id, "tab_id": tab_id, "path": [], "ratio": 0.7},
        )
        snap3 = request(
            self.socket_path,
            "layout.snapshot",
            {"workspace_id": ws_id, "tab_id": tab_id},
        )
        self.assertAlmostEqual(snap3["result"]["tree"]["root"]["ratio"], 0.7, places=2)

        # Close the new pane → root collapses back to a single pane.
        request(self.socket_path, "pane.close", {"pane_id": new_pane_id})
        snap4 = request(
            self.socket_path,
            "layout.snapshot",
            {"workspace_id": ws_id, "tab_id": tab_id},
        )
        self.assertEqual(snap4["result"]["tree"]["root"].get("kind"), "pane")
        # After close, the surviving pane is the original.
        self.assertEqual(snap4["result"]["tree"]["root"]["pane_id"], first_pane_id)

        # Cleanup.
        request(self.socket_path, "workspace.close", {"workspace_id": ws_id})

    def test_events_subscribe_emits_workspace_created(self):
        # Long-lived events.subscribe connection.
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(3.0)
        sock.connect(self.socket_path)
        sub = {
            "id": "sub-1",
            "method": "events.subscribe",
            "params": {"subscriptions": [{"type": "workspace.created"}]},
        }
        sock.sendall((json.dumps(sub) + "\n").encode("utf-8"))

        # Trigger via separate one-shot socket.
        resp = request(
            self.socket_path,
            "workspace.create",
            {"focus": False, "label": "wire-event"},
        )
        ws_id = resp["result"]["workspace"]["workspace_id"]

        # Read events until we see workspace.created or hit timeout.
        buffer = b""
        deadline = time.time() + 3.0
        saw = False
        while time.time() < deadline:
            try:
                chunk = sock.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                if not line:
                    continue
                try:
                    msg = json.loads(line.decode("utf-8"))
                except json.JSONDecodeError:
                    continue
                event_kind = msg.get("event") or msg.get("kind")
                if event_kind in ("workspace.created", "workspace_created"):
                    saw = True
                    break
            if saw:
                break

        sock.close()
        request(self.socket_path, "workspace.close", {"workspace_id": ws_id})
        self.assertTrue(saw, "did not receive workspace.created event within 3s")


if __name__ == "__main__":
    if not find_herdr_cmux():
        print("herdr-cmux not found; skipping wire protocol tests")
        sys.exit(0)
    unittest.main(verbosity=2)
