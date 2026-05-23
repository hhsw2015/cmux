//! M4a-L2: layout.snapshot end-to-end against real tmux.
//!
//! Two flows:
//! * happy path — create session, split, snapshot returns a
//!   binary BSP tree with horizontal split direction;
//! * compat probe — calling snapshot with a non-existent
//!   tab_id returns `tab_not_found`, mirroring cmux's
//!   `probeCapabilities` expectations.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::Value;

fn tmux_available() -> bool {
    Command::new("tmux")
        .arg("-V")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn unique_tmpdir() -> PathBuf {
    let pid = std::process::id();
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let p = PathBuf::from(format!("/tmp/cmux-tmux-lay-{pid}-{nanos}"));
    std::fs::create_dir_all(&p).expect("mkdir tmpdir");
    p
}

struct Shim {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<std::process::ChildStdout>,
}

impl Shim {
    fn spawn(tmpdir: &Path) -> Self {
        let bin = env!("CARGO_BIN_EXE_cmux-tmux");
        let mut child = Command::new(bin)
            .arg("serve")
            .env("TMUX_TMPDIR", tmpdir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("spawn shim");
        let stdin = child.stdin.take().unwrap();
        let stdout = BufReader::new(child.stdout.take().unwrap());
        Self {
            child,
            stdin,
            stdout,
        }
    }

    fn call(&mut self, request: Value) -> Value {
        let line = serde_json::to_string(&request).unwrap();
        writeln!(self.stdin, "{line}").expect("write request");
        self.stdin.flush().unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut buf = String::new();
        loop {
            buf.clear();
            let n = self.stdout.read_line(&mut buf).expect("read response");
            if n == 0 {
                panic!("shim closed stdout");
            }
            if !buf.trim().is_empty() {
                break;
            }
            if Instant::now() > deadline {
                panic!("response timeout");
            }
        }
        serde_json::from_str(buf.trim()).expect("response is JSON")
    }
}

impl Drop for Shim {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn kill_tmux_server(tmpdir: &Path) {
    let _ = Command::new("tmux")
        .env("TMUX_TMPDIR", tmpdir)
        .args(["kill-server"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

fn first_window_id(tmpdir: &Path, session: &str) -> String {
    let out = Command::new("tmux")
        .env("TMUX_TMPDIR", tmpdir)
        .args(["list-windows", "-t", session, "-F", "#{window_id}"])
        .output()
        .expect("list-windows");
    assert!(out.status.success());
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .next()
        .unwrap()
        .trim()
        .to_string()
}

#[test]
fn layout_snapshot_returns_bsp_tree_after_split() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }

    let tmpdir = unique_tmpdir();
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut shim = Shim::spawn(&tmpdir);

        let create = shim.call(serde_json::json!({
            "id": "1",
            "method": "workspace.create",
            "params": { "name": "lay" }
        }));
        let workspace_id = create["result"]["workspace_id"]
            .as_str()
            .unwrap()
            .to_string();

        // Single-pane snapshot: tree.root is a leaf Pane.
        let tab_id = first_window_id(&tmpdir, "lay");
        let snap1 = shim.call(serde_json::json!({
            "id": "2",
            "method": "layout.snapshot",
            "params": { "workspace_id": workspace_id, "tab_id": tab_id }
        }));
        let tree1 = &snap1["result"]["tree"];
        assert_eq!(tree1["workspace_id"], serde_json::json!(workspace_id));
        assert_eq!(tree1["tab_id"], serde_json::json!(tab_id));
        assert_eq!(tree1["root"]["kind"], serde_json::json!("pane"));
        assert!(tree1["root"]["pane_id"].as_str().unwrap().starts_with('%'));
        assert!(tree1["focused_pane_id"].is_string());

        // Split horizontally; snapshot now has a horizontal
        // BSP split with two pane leaves.
        let panes = shim.call(serde_json::json!({
            "id": "3",
            "method": "panes.list",
            "params": { "workspace_id": workspace_id }
        }));
        let target = panes["result"]["panes"][0]["pane_id"]
            .as_str()
            .unwrap()
            .to_string();
        let _ = shim.call(serde_json::json!({
            "id": "4",
            "method": "pane.split",
            "params": { "target_pane_id": target, "direction": "right" }
        }));

        let snap2 = shim.call(serde_json::json!({
            "id": "5",
            "method": "layout.snapshot",
            "params": { "workspace_id": workspace_id, "tab_id": tab_id }
        }));
        let tree2 = &snap2["result"]["tree"];
        assert_eq!(tree2["root"]["kind"], serde_json::json!("split"));
        assert_eq!(
            tree2["root"]["direction"],
            serde_json::json!("horizontal"),
            "expected horizontal split, got {snap2}"
        );
        let ratio = tree2["root"]["ratio"].as_f64().expect("ratio is a number");
        assert!((0.0..=1.0).contains(&ratio), "ratio {ratio} out of range");
        assert_eq!(tree2["root"]["first"]["kind"], serde_json::json!("pane"));
        assert_eq!(tree2["root"]["second"]["kind"], serde_json::json!("pane"));
    }));

    kill_tmux_server(&tmpdir);
    let _ = std::fs::remove_dir_all(&tmpdir);
    if let Err(e) = result {
        std::panic::resume_unwind(e);
    }
}

#[test]
fn pane_set_split_ratio_resizes_via_path_addressing() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }

    let tmpdir = unique_tmpdir();
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut shim = Shim::spawn(&tmpdir);

        let create = shim.call(serde_json::json!({
            "id": "1",
            "method": "workspace.create",
            "params": { "name": "ssr" }
        }));
        let workspace_id = create["result"]["workspace_id"]
            .as_str()
            .unwrap()
            .to_string();
        let tab_id = first_window_id(&tmpdir, "ssr");

        // Split horizontally so we have a 2-child split (path
        // is empty == root split).
        let panes = shim.call(serde_json::json!({
            "id": "2",
            "method": "panes.list",
            "params": { "workspace_id": workspace_id }
        }));
        let target = panes["result"]["panes"][0]["pane_id"]
            .as_str()
            .unwrap()
            .to_string();
        let _ = shim.call(serde_json::json!({
            "id": "3",
            "method": "pane.split",
            "params": { "target_pane_id": target, "direction": "right" }
        }));

        let snap_pre = shim.call(serde_json::json!({
            "id": "4",
            "method": "layout.snapshot",
            "params": { "workspace_id": workspace_id, "tab_id": tab_id }
        }));
        let pre_ratio = snap_pre["result"]["tree"]["root"]["ratio"]
            .as_f64()
            .expect("pre ratio");

        // Drag the divider: target ratio 0.25 (small first pane).
        let resp = shim.call(serde_json::json!({
            "id": "5",
            "method": "pane.set_split_ratio",
            "params": {
                "workspace_id": workspace_id,
                "tab_id": tab_id,
                "path": [],
                "ratio": 0.25,
            }
        }));
        assert!(resp.get("error").is_none(), "got error: {resp}");

        let snap_post = shim.call(serde_json::json!({
            "id": "6",
            "method": "layout.snapshot",
            "params": { "workspace_id": workspace_id, "tab_id": tab_id }
        }));
        let post_ratio = snap_post["result"]["tree"]["root"]["ratio"]
            .as_f64()
            .expect("post ratio");

        // Ratio should be visibly closer to 0.25 than to the
        // pre-drag value (which started near 0.5).
        let pre_err = (pre_ratio - 0.25).abs();
        let post_err = (post_ratio - 0.25).abs();
        assert!(
            post_err < pre_err,
            "post_ratio {post_ratio} (err {post_err}) should be closer to 0.25 than pre {pre_ratio} (err {pre_err})"
        );
    }));

    kill_tmux_server(&tmpdir);
    let _ = std::fs::remove_dir_all(&tmpdir);
    if let Err(e) = result {
        std::panic::resume_unwind(e);
    }
}

#[test]
fn layout_snapshot_unknown_tab_returns_tab_not_found() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }

    let tmpdir = unique_tmpdir();
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut shim = Shim::spawn(&tmpdir);
        // No workspace created; the bin will spawn tmux against
        // an empty server and display-message returns empty
        // stdout, which we map to tab_not_found. This matches
        // cmux's HerdrBackend.probeCapabilities expectations.
        let probe = shim.call(serde_json::json!({
            "id": "p",
            "method": "layout.snapshot",
            "params": {
                "workspace_id": "_cmux_probe_",
                "tab_id": "_cmux_probe_:1"
            }
        }));
        let err = probe["error"].as_object().expect("probe should error");
        assert_eq!(
            err["code"].as_str().unwrap(),
            "tab_not_found",
            "got error: {probe}"
        );
    }));

    kill_tmux_server(&tmpdir);
    let _ = std::fs::remove_dir_all(&tmpdir);
    if let Err(e) = result {
        std::panic::resume_unwind(e);
    }
}
