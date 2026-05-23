//! I3: attach to a tmux pane running `cat`, write bytes to the
//! shim's stdin, expect them echoed back on stdout.
//!
//! Each test creates its own tmux server in a unique
//! /tmp/cmux-tmux-rpa-* dir and tears it down on exit.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
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
    let pid = std::process::id();
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let p = PathBuf::from(format!("/tmp/cmux-tmux-rpa-{pid}-{nanos}"));
    std::fs::create_dir_all(&p).expect("mkdir tmpdir");
    p
}

fn tmux(tmpdir: &Path) -> Command {
    let mut c = Command::new("tmux");
    c.env("TMUX_TMPDIR", tmpdir);
    c
}

fn kill_tmux_server(tmpdir: &Path) {
    let _ = tmux(tmpdir)
        .arg("kill-server")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

fn first_pane_id(tmpdir: &Path, session: &str) -> String {
    let out = tmux(tmpdir)
        .args(["list-panes", "-t", session, "-F", "#{pane_id}"])
        .output()
        .expect("list-panes");
    assert!(out.status.success(), "list-panes failed: {out:?}");
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .next()
        .expect("at least one pane")
        .trim()
        .to_string()
}

#[test]
fn raw_pty_attach_echoes_through_cat() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }

    let tmpdir = unique_tmpdir();
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        // Detached session running cat.
        let create = tmux(&tmpdir)
            .args([
                "new-session",
                "-d",
                "-x",
                "80",
                "-y",
                "24",
                "-s",
                "rpa",
                "cat",
            ])
            .status()
            .expect("new-session");
        assert!(create.success(), "new-session failed");

        // Cat needs a moment to come up so its tty is ready to
        // receive keys.
        std::thread::sleep(Duration::from_millis(100));

        let pane = first_pane_id(&tmpdir, "rpa");
        assert!(pane.starts_with('%'));

        let bin = env!("CARGO_BIN_EXE_cmux-tmux");
        let mut child = Command::new(bin)
            .args(["raw-pty-attach", "--pane", &pane])
            .env("TMUX_TMPDIR", &tmpdir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("spawn raw-pty-attach");

        let stdin = child.stdin.as_mut().unwrap();
        // cat reads a line, then echoes it once \r is sent. We
        // send `hello\r` so cat's tty driver delivers the line.
        stdin.write_all(b"hello\r").expect("write hello");
        stdin.flush().unwrap();

        // Read up to 256 bytes off stdout with a deadline. cat
        // echoes what it gets; the tmux pane tty also echoes the
        // input typed at it. So we should see "hello" appear in
        // the byte stream within a couple seconds.
        let mut stdout = child.stdout.take().unwrap();
        let (tx, rx) = std::sync::mpsc::channel::<Vec<u8>>();
        std::thread::spawn(move || {
            let mut buf = vec![0u8; 4096];
            let mut acc = Vec::new();
            let deadline = Instant::now() + Duration::from_secs(3);
            while Instant::now() < deadline && acc.len() < 1024 {
                match stdout.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        acc.extend_from_slice(&buf[..n]);
                        if acc.windows(5).any(|w| w == b"hello") {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
            let _ = tx.send(acc);
        });

        let collected = rx
            .recv_timeout(Duration::from_secs(4))
            .expect("collect within 4s");

        let _ = child.kill();
        let _ = child.wait();

        assert!(
            collected.windows(5).any(|w| w == b"hello"),
            "expected 'hello' in output, got {:?}",
            String::from_utf8_lossy(&collected)
        );
    }));

    kill_tmux_server(&tmpdir);
    let _ = std::fs::remove_dir_all(&tmpdir);
    if let Err(e) = result {
        std::panic::resume_unwind(e);
    }
}
