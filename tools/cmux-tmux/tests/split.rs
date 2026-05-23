//! I1: workspace.create -> pane.split -> panes.list end-to-end
//! against a real tmux server. Each test uses a unique
//! `TMUX_TMPDIR` so concurrent runs don't collide and so the
//! suite leaves the host tmux server untouched.
//!
//! Skipped silently if tmux isn't on PATH.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

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
    // tmux socket paths are bounded by sun_path (~104 bytes on
    // macOS), so we can't use std::env::temp_dir() — that points
    // at /private/var/folders/.../T/ which already eats most of
    // the budget. /tmp keeps us well below.
    let pid = std::process::id();
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let p = PathBuf::from(format!("/tmp/cmux-tmux-it-{pid}-{nanos}"));
    std::fs::create_dir_all(&p).expect("mkdir tmpdir");
    p
}

struct Shim {
    child: std::process::Child,
    stdin: std::process::ChildStdin,
    stdout: BufReader<std::process::ChildStdout>,
}

impl Shim {
    fn spawn(tmux_tmpdir: &PathBuf) -> Self {
        let bin = env!("CARGO_BIN_EXE_cmux-tmux");
        let mut child = Command::new(bin)
            .arg("serve")
            .env("TMUX_TMPDIR", tmux_tmpdir)
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

    fn call(&mut self, request: &serde_json::Value) -> serde_json::Value {
        let line = serde_json::to_string(request).unwrap();
        writeln!(self.stdin, "{line}").expect("write request");
        self.stdin.flush().unwrap();

        // Read with a deadline so a wedged shim fails the test
        // instead of the suite.
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut buf = String::new();
        loop {
            buf.clear();
            let n = self.stdout.read_line(&mut buf).expect("read response");
            if n == 0 {
                panic!("shim closed stdout unexpectedly");
            }
            if !buf.trim().is_empty() {
                break;
            }
            if Instant::now() > deadline {
                panic!("shim response timeout");
            }
        }
        serde_json::from_str(buf.trim()).expect("response is JSON")
    }
}

impl Drop for Shim {
    fn drop(&mut self) {
        // Closing stdin signals EOF; bin's serve loop exits.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn kill_tmux_server(tmux_tmpdir: &PathBuf) {
    let _ = Command::new("tmux")
        .env("TMUX_TMPDIR", tmux_tmpdir)
        .args(["kill-server"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

#[test]
fn create_split_list() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }

    let tmpdir = unique_tmpdir();

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut shim = Shim::spawn(&tmpdir);

        // workspace.create
        let create = shim.call(&serde_json::json!({
            "id": "1",
            "method": "workspace.create",
            "params": { "name": "it-test" }
        }));
        assert!(create.get("error").is_none(), "create errored: {create}");
        let workspace_id = create["result"]["workspace_id"]
            .as_str()
            .expect("workspace_id present")
            .to_string();
        assert!(workspace_id.starts_with('$'), "id was {workspace_id:?}");

        // panes.list right after create — should have one pane.
        let list_one = shim.call(&serde_json::json!({
            "id": "2",
            "method": "panes.list",
            "params": { "workspace_id": workspace_id }
        }));
        let panes_one = list_one["result"]["panes"]
            .as_array()
            .expect("panes array")
            .clone();
        assert_eq!(panes_one.len(), 1, "expected 1 pane, got {list_one}");
        let first_pane = panes_one[0]["pane_id"].as_str().unwrap().to_string();
        assert!(first_pane.starts_with('%'));

        // pane.split horizontal.
        let split = shim.call(&serde_json::json!({
            "id": "3",
            "method": "pane.split",
            "params": {
                "target_pane_id": first_pane,
                "direction": "right"
            }
        }));
        assert!(split.get("error").is_none(), "split errored: {split}");
        let new_pane = split["result"]["pane_id"]
            .as_str()
            .expect("new pane id")
            .to_string();
        assert!(new_pane.starts_with('%'));
        assert_ne!(new_pane, first_pane);

        // panes.list again — should be 2.
        let list_two = shim.call(&serde_json::json!({
            "id": "4",
            "method": "panes.list",
            "params": { "workspace_id": workspace_id }
        }));
        let panes_two = list_two["result"]["panes"].as_array().unwrap();
        assert_eq!(panes_two.len(), 2, "expected 2 panes, got {list_two}");
    }));

    kill_tmux_server(&tmpdir);
    let _ = std::fs::remove_dir_all(&tmpdir);
    if let Err(e) = result {
        std::panic::resume_unwind(e);
    }
}
