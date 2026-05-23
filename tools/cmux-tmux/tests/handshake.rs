//! I0: spawn the cmux-tmux binary in stdio serve mode, send a
//! single `ping` JSON-RPC request, expect `pong` back. No tmux
//! involvement — this is purely the bin -> lib glue.

use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};
use std::time::Duration;

#[test]
fn serve_responds_to_ping_with_pong() {
    let bin = env!("CARGO_BIN_EXE_cmux-tmux");
    let mut child = Command::new(bin)
        // Match cmux's invocation pattern: --session NAME goes
        // before the subcommand. The flag is accepted today
        // (cosmetic) so cmux SSHCommandBuilder.build doesn't
        // need a special case.
        .args(["--session", "test-session", "serve"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn cmux-tmux");

    {
        let stdin = child.stdin.as_mut().expect("stdin");
        stdin
            .write_all(b"{\"id\":\"1\",\"method\":\"ping\",\"params\":{}}\n")
            .expect("write request");
        stdin.flush().expect("flush");
    }

    // Read one response line on a worker thread so we can bound
    // the wait — a hung child should fail the test, not the
    // suite.
    let stdout = child.stdout.take().expect("stdout");
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut reader = BufReader::new(stdout);
        let mut line = String::new();
        let _ = reader.read_line(&mut line);
        let _ = tx.send(line);
    });

    let line = rx
        .recv_timeout(Duration::from_secs(2))
        .expect("response within 2s");

    // Drop stdin and reap.
    drop(child.stdin.take());
    let _ = child.wait();

    let resp: serde_json::Value =
        serde_json::from_str(line.trim()).expect("response is valid JSON");
    assert_eq!(resp["id"], serde_json::json!("1"));
    assert_eq!(resp["result"]["protocol"], serde_json::json!(1));
    assert!(resp["result"]["version"].is_string());
}
