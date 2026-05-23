//! I4: reattach replays the pane buffer. Pre-load a marker into
//! a pane, then spawn raw-pty-attach and expect the marker to
//! appear in the first chunk of output (replayed from
//! `tmux capture-pane -e -p`).

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread::sleep;
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
    let p = PathBuf::from(format!("/tmp/cmux-tmux-rst-{pid}-{nanos}"));
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
    assert!(out.status.success());
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .next()
        .unwrap()
        .trim()
        .to_string()
}

#[test]
fn reattach_replays_capture_pane_buffer() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }

    let tmpdir = unique_tmpdir();
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        // Detached session running cat — anything we send-keys
        // to it gets echoed and shows up in the pane buffer.
        assert!(tmux(&tmpdir)
            .args([
                "new-session",
                "-d",
                "-x",
                "80",
                "-y",
                "24",
                "-s",
                "rst",
                "cat",
            ])
            .status()
            .unwrap()
            .success());

        sleep(Duration::from_millis(100));
        let pane = first_pane_id(&tmpdir, "rst");

        // Pre-load a marker by sending keys to the pane via a
        // normal tmux invocation. cat echoes it; the rendered
        // text lands in the pane's grid where capture-pane can
        // see it.
        assert!(tmux(&tmpdir)
            .args(["send-keys", "-t", &pane, "RESTORE_MARKER_42", "Enter",])
            .status()
            .unwrap()
            .success());
        sleep(Duration::from_millis(200));

        // Spawn raw-pty-attach. It should replay the pane
        // contents (which now contain the marker) before any
        // live stream starts.
        let bin = env!("CARGO_BIN_EXE_cmux-tmux");
        let mut child = Command::new(bin)
            .args(["raw-pty-attach", "--pane", &pane])
            .env("TMUX_TMPDIR", &tmpdir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("spawn shim");

        let mut stdout = child.stdout.take().unwrap();
        let (tx, rx) = std::sync::mpsc::channel::<Vec<u8>>();
        std::thread::spawn(move || {
            let mut buf = vec![0u8; 4096];
            let mut acc = Vec::new();
            let deadline = Instant::now() + Duration::from_secs(2);
            while Instant::now() < deadline && acc.len() < 8192 {
                match stdout.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        acc.extend_from_slice(&buf[..n]);
                        if acc
                            .windows(b"RESTORE_MARKER_42".len())
                            .any(|w| w == b"RESTORE_MARKER_42")
                        {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
            let _ = tx.send(acc);
        });

        let collected = rx
            .recv_timeout(Duration::from_secs(3))
            .expect("collect within 3s");

        let _ = child.kill();
        let _ = child.wait();

        assert!(
            collected
                .windows(b"RESTORE_MARKER_42".len())
                .any(|w| w == b"RESTORE_MARKER_42"),
            "expected RESTORE_MARKER_42 in replayed output, got {:?}",
            String::from_utf8_lossy(&collected)
        );
    }));

    kill_tmux_server(&tmpdir);
    let _ = std::fs::remove_dir_all(&tmpdir);
    if let Err(e) = result {
        std::panic::resume_unwind(e);
    }
}
