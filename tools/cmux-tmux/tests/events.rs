//! I2: subscribe to events on a workspace, perform a split via
//! a separate tmux invocation, expect a `layout_changed`
//! notification on the bin's stdout.
//!
//! The shim's `events.subscribe` spawns a long-lived
//! `tmux -C attach -d -t <workspace_id>` over pipes; its reader
//! thread feeds Session::feed and emits CPP-event JSON
//! notifications (objects with no `id` field) to the same
//! stdout the RPC responses use. The test fixture below
//! demultiplexes by presence of `id`.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;

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
    // tmux sun_path budget; see tests/split.rs for context.
    let pid = std::process::id();
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let p = PathBuf::from(format!("/tmp/cmux-tmux-evt-{pid}-{nanos}"));
    std::fs::create_dir_all(&p).expect("mkdir tmpdir");
    p
}

struct Shim {
    child: Child,
    stdin: ChildStdin,
    response_rx: Receiver<Value>,
    event_rx: Receiver<Value>,
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
        let stdout = child.stdout.take().unwrap();

        let (resp_tx, resp_rx) = mpsc::channel::<Value>();
        let (ev_tx, ev_rx) = mpsc::channel::<Value>();

        std::thread::spawn(move || {
            let reader = BufReader::new(stdout);
            for line in reader.lines() {
                let Ok(line) = line else {
                    break;
                };
                if line.trim().is_empty() {
                    continue;
                }
                let v: Value = match serde_json::from_str(&line) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                if v.get("id").is_some() {
                    if resp_tx.send(v).is_err() {
                        break;
                    }
                } else if ev_tx.send(v).is_err() {
                    break;
                }
            }
        });

        Self {
            child,
            stdin,
            response_rx: resp_rx,
            event_rx: ev_rx,
        }
    }

    fn call(&mut self, request: Value) -> Value {
        let line = serde_json::to_string(&request).unwrap();
        writeln!(self.stdin, "{line}").expect("write request");
        self.stdin.flush().unwrap();
        self.response_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("response within 5s")
    }

    fn next_event(&self, timeout: Duration) -> Option<Value> {
        self.event_rx.recv_timeout(timeout).ok()
    }
}

impl Drop for Shim {
    fn drop(&mut self) {
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
fn subscribe_then_split_emits_layout_changed() {
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
            "params": { "name": "evt" }
        }));
        let workspace_id = create["result"]["workspace_id"]
            .as_str()
            .expect("workspace_id present")
            .to_string();

        // Subscribe — spawns the control client.
        let sub = shim.call(serde_json::json!({
            "id": "2",
            "method": "events.subscribe",
            "params": { "workspace_id": workspace_id }
        }));
        assert_eq!(sub["result"]["subscribed"], serde_json::json!(true));

        // Drain any startup events (initial layout-change on
        // attach is normal). We only care about the split-
        // induced one below.
        while shim.next_event(Duration::from_millis(300)).is_some() {}

        // Split via a normal tmux invocation against the same
        // server (TMUX_TMPDIR carried via env on shim spawn,
        // and we use the same tmpdir here).
        let panes = shim.call(serde_json::json!({
            "id": "3",
            "method": "panes.list",
            "params": { "workspace_id": workspace_id }
        }));
        let target = panes["result"]["panes"][0]["pane_id"]
            .as_str()
            .expect("first pane id")
            .to_string();

        let split = shim.call(serde_json::json!({
            "id": "4",
            "method": "pane.split",
            "params": {
                "target_pane_id": target,
                "direction": "right"
            }
        }));
        assert!(split.get("error").is_none(), "split errored: {split}");

        // Wait for a layout_changed event with a small budget.
        let mut found = None;
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while std::time::Instant::now() < deadline {
            if let Some(ev) = shim.next_event(Duration::from_millis(200)) {
                if ev["event"] == serde_json::json!("layout_changed") {
                    found = Some(ev);
                    break;
                }
            }
        }
        let ev = found.expect("layout_changed event within 3s");
        assert!(ev["window_id"].is_string());
        assert!(ev["layout_string"].is_string());
    }));

    kill_tmux_server(&tmpdir);
    let _ = std::fs::remove_dir_all(&tmpdir);
    if let Err(e) = result {
        std::panic::resume_unwind(e);
    }
}
