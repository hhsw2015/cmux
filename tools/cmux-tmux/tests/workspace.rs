//! W1+W2: workspace.attach + workspace.rename + workspace.close
//! against a real tmux server.

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
    let p = PathBuf::from(format!("/tmp/cmux-tmux-ws-{pid}-{nanos}"));
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

#[test]
fn attach_rename_close_lifecycle() {
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
            "params": { "name": "ws-it" }
        }));
        let workspace_id = create["result"]["workspace_id"]
            .as_str()
            .expect("workspace_id")
            .to_string();

        // attach: panes array + echoed workspace_id
        let attach = shim.call(serde_json::json!({
            "id": "2",
            "method": "workspace.attach",
            "params": { "workspace_id": workspace_id }
        }));
        assert_eq!(
            attach["result"]["workspace_id"],
            serde_json::json!(workspace_id)
        );
        let panes = attach["result"]["panes"].as_array().expect("panes array");
        assert_eq!(panes.len(), 1);

        // rename: result is just `true`, but list-sessions
        // confirms the new name.
        let rename = shim.call(serde_json::json!({
            "id": "3",
            "method": "workspace.rename",
            "params": { "workspace_id": workspace_id, "name": "ws-it-renamed" }
        }));
        assert_eq!(rename["result"], serde_json::json!(true));

        let list = shim.call(serde_json::json!({
            "id": "4",
            "method": "workspace.list",
            "params": {}
        }));
        let workspaces = list["result"]["workspaces"]
            .as_array()
            .expect("workspaces array");
        let renamed = workspaces
            .iter()
            .find(|w| w["workspace_id"].as_str() == Some(&workspace_id));
        assert_eq!(
            renamed.expect("renamed session present")["name"],
            serde_json::json!("ws-it-renamed")
        );

        // close
        let close = shim.call(serde_json::json!({
            "id": "5",
            "method": "workspace.close",
            "params": { "workspace_id": workspace_id }
        }));
        assert_eq!(close["result"], serde_json::json!(true));

        // After close, list-sessions either errors (no server)
        // or returns an empty list. Both are fine.
        let after = shim.call(serde_json::json!({
            "id": "6",
            "method": "workspace.list",
            "params": {}
        }));
        if after.get("error").is_none() {
            let workspaces = after["result"]["workspaces"]
                .as_array()
                .expect("workspaces array");
            assert!(
                !workspaces
                    .iter()
                    .any(|w| w["workspace_id"].as_str() == Some(&workspace_id)),
                "closed workspace still present: {after}"
            );
        }
    }));

    kill_tmux_server(&tmpdir);
    let _ = std::fs::remove_dir_all(&tmpdir);
    if let Err(e) = result {
        std::panic::resume_unwind(e);
    }
}
