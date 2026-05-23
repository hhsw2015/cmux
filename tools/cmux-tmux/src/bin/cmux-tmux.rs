//! cmux-tmux entry point. The bin is the only place that does
//! I/O. All translation / parsing lives in the lib.
//!
//! Subcommands:
//!
//! * `serve` — line-delimited JSON-RPC on stdin/stdout. Used as
//!   the cmux pane protocol (CPP) endpoint. Responses are written
//!   in the order requests arrive on stdin; events from a
//!   subscribed `tmux -C` control session interleave on stdout
//!   as JSON notifications (objects without an `id` field).
//! * `raw-pty-attach` — to be implemented in stage 4.

use std::io::{self, BufRead, BufReader, Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};

use cmux_tmux::bsp::{walk_split_path, BspSplitDirection};
use cmux_tmux::parse::{parse_layout, Session};
use cmux_tmux::pty::{bytes_to_send_keys_argv, decode_output_event};
use cmux_tmux::tmux_response::{capture_args_for, event_to_json, shape_response_with_params};
use cmux_tmux::translate::{
    self, translate_request, ErrorObject, ErrorResponse, TranslateError, TranslateOutcome,
};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let exit = match args.first().map(String::as_str) {
        Some("serve") => serve(),
        Some("raw-pty-attach") => raw_pty_attach(&args[1..]),
        Some(other) => {
            eprintln!("unknown subcommand: {other}");
            2
        }
        None => {
            eprintln!("usage: cmux-tmux serve | cmux-tmux raw-pty-attach --pane %N");
            2
        }
    };
    std::process::exit(exit);
}

/// `raw-pty-attach --pane %N`: bidirectional byte stream between
/// the caller's stdio and a tmux pane. stdin -> `tmux send-keys
/// -H ...`; tmux's `%output` events for the target pane decode
/// back to bytes on stdout. Runs until either side closes.
fn raw_pty_attach(args: &[String]) -> i32 {
    let mut pane: Option<String> = None;
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--pane" => pane = iter.next().cloned(),
            other => {
                eprintln!("raw-pty-attach: unknown arg {other}");
                return 2;
            }
        }
    }
    let Some(pane) = pane else {
        eprintln!("raw-pty-attach: --pane <id> is required");
        return 2;
    };

    // Replay the pane's current rendered contents on attach so
    // the caller sees what's already there. tmux's capture-pane
    // is the closest thing tmux has to herdr's raw_pty_history;
    // it returns rendered text + escapes, not the raw byte
    // history (see PLAN.md known-loss list).
    if let Ok(out) = Command::new("tmux")
        .args(["capture-pane", "-e", "-p", "-t", &pane])
        .output()
    {
        if out.status.success() {
            let stdout = io::stdout();
            let mut lock = stdout.lock();
            let _ = lock.write_all(&out.stdout);
            let _ = lock.flush();
        }
    }

    let mut control = match Command::new("tmux")
        .args(["-C", "attach", "-d"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            eprintln!("raw-pty-attach: spawn tmux -C: {e}");
            return 1;
        }
    };

    let control_stdout = control.stdout.take().expect("tmux -C stdout");
    let target_pane = pane.clone();

    // tmux -> client.
    let reader = std::thread::spawn(move || {
        let stdout = io::stdout();
        let mut out = stdout.lock();
        let reader = BufReader::new(control_stdout);
        for line in reader.lines() {
            let Ok(line) = line else {
                break;
            };
            if let Some((p, bytes)) = decode_output_event(&line) {
                if p == target_pane {
                    if out.write_all(&bytes).is_err() {
                        break;
                    }
                    if out.flush().is_err() {
                        break;
                    }
                }
            }
        }
    });

    // Client -> tmux. We block the main thread on stdin so
    // closing it (the natural EOF signal) tears the whole thing
    // down.
    let mut buf = [0u8; 4096];
    let stdin = io::stdin();
    let mut stdin_lock = stdin.lock();
    loop {
        let n = match stdin_lock.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(_) => break,
        };
        let argv = bytes_to_send_keys_argv(&pane, &buf[..n]);
        if argv.is_empty() {
            continue;
        }
        let status = Command::new("tmux").args(&argv).status();
        if status.map(|s| !s.success()).unwrap_or(true) {
            break;
        }
    }

    let _ = control.kill();
    let _ = control.wait();
    let _ = reader.join();
    0
}

/// Worker thread sink: every line written to stdout goes through
/// this channel so request-reply and event notifications don't
/// interleave inside a single line.
fn spawn_writer() -> Sender<String> {
    let (tx, rx) = mpsc::channel::<String>();
    std::thread::spawn(move || {
        let stdout = io::stdout();
        let mut out = stdout.lock();
        while let Ok(line) = rx.recv() {
            if writeln!(out, "{line}").is_err() {
                break;
            }
            if out.flush().is_err() {
                break;
            }
        }
    });
    tx
}

fn serve() -> i32 {
    let writer = spawn_writer();
    // Subscribed control clients are kept alive for the lifetime
    // of the serve loop; killing them on Drop is enough cleanup.
    let control: Arc<Mutex<Option<Child>>> = Arc::new(Mutex::new(None));

    let stdin = io::stdin();
    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(e) => {
                let _ = writer.send(error_envelope(
                    serde_json::Value::Null,
                    translate::INTERNAL_ERROR,
                    &e.to_string(),
                ));
                return 1;
            }
        };
        if line.trim().is_empty() {
            continue;
        }

        let response = handle_line(&line, &control, &writer);
        if writer.send(response).is_err() {
            return 1;
        }
    }
    0
}

fn handle_line(line: &str, control: &Arc<Mutex<Option<Child>>>, writer: &Sender<String>) -> String {
    let id = parse_id(line);
    let method = parse_method(line);

    if method == "events.subscribe" {
        return subscribe_events(line, id, control, writer);
    }
    if method == "pane.set_split_ratio" {
        return apply_set_split_ratio(line, id);
    }

    match translate_request(line) {
        Ok(TranslateOutcome::ImmediateResponse(r)) => {
            serde_json::to_string(&r).unwrap_or_else(|e| {
                error_envelope(
                    serde_json::Value::Null,
                    translate::INTERNAL_ERROR,
                    &e.to_string(),
                )
            })
        }
        Ok(TranslateOutcome::ImmediateError(e)) => {
            serde_json::to_string(&e).unwrap_or_else(|err| {
                error_envelope(
                    serde_json::Value::Null,
                    translate::INTERNAL_ERROR,
                    &err.to_string(),
                )
            })
        }
        Ok(TranslateOutcome::RunTmux(argv)) => run_tmux_and_shape(id, &method, argv, line),
        Ok(TranslateOutcome::RunMulti(_)) => error_envelope(
            id,
            translate::INTERNAL_ERROR,
            "multi-step requests not yet wired",
        ),
        Err(TranslateError::InvalidJson(e)) => error_envelope(
            serde_json::Value::Null,
            translate::INVALID_REQUEST,
            &e.to_string(),
        ),
        Err(other) => error_envelope(id, translate::INTERNAL_ERROR, &other.to_string()),
    }
}

fn subscribe_events(
    line: &str,
    id: serde_json::Value,
    control: &Arc<Mutex<Option<Child>>>,
    writer: &Sender<String>,
) -> String {
    let workspace_id = serde_json::from_str::<serde_json::Value>(line)
        .ok()
        .and_then(|v| {
            v.get("params")
                .and_then(|p| p.get("workspace_id"))
                .and_then(|w| w.as_str().map(str::to_string))
        });
    let Some(workspace_id) = workspace_id else {
        return error_envelope(
            id,
            translate::INTERNAL_ERROR,
            "events.subscribe requires workspace_id",
        );
    };

    let mut guard = control.lock().expect("control mutex");
    if guard.is_some() {
        // Already subscribed; idempotent ack.
        return success_envelope(&id, &serde_json::json!({"subscribed": true}));
    }

    let child = match spawn_control_client(&workspace_id, writer.clone()) {
        Ok(c) => c,
        Err(e) => {
            return error_envelope(id, translate::TMUX_FAILED, &format!("spawn tmux -C: {e}"))
        }
    };
    *guard = Some(child);
    success_envelope(&id, &serde_json::json!({"subscribed": true}))
}

fn spawn_control_client(workspace_id: &str, writer: Sender<String>) -> io::Result<Child> {
    let mut child = Command::new("tmux")
        .args(["-C", "attach", "-d", "-t", workspace_id])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| io::Error::other("tmux -C produced no stdout pipe"))?;
    std::thread::spawn(move || {
        let mut session = Session::default();
        let reader = BufReader::new(stdout);
        for line in reader.lines() {
            let Ok(line) = line else {
                break;
            };
            for ev in session.feed(&line) {
                let json = event_to_json(&ev);
                let s = serde_json::to_string(&json).unwrap_or_default();
                if writer.send(s).is_err() {
                    return;
                }
            }
        }
    });
    Ok(child)
}

fn parse_id(line: &str) -> serde_json::Value {
    serde_json::from_str::<serde_json::Value>(line)
        .ok()
        .and_then(|v| v.get("id").cloned())
        .unwrap_or(serde_json::Value::Null)
}

fn parse_method(line: &str) -> String {
    serde_json::from_str::<serde_json::Value>(line)
        .ok()
        .and_then(|v| v.get("method").and_then(|m| m.as_str().map(str::to_string)))
        .unwrap_or_default()
}

/// `pane.set_split_ratio({workspace_id, tab_id, path, ratio})`.
///
/// cmux's HerdrDividerSync fires this on every divider drag,
/// addressing splits by a `[Bool]` path through the BSP
/// projection of the tab layout. tmux can only resize a
/// concrete pane, so we:
///   1. read the live tmux layout via `display-message`;
///   2. parse it and walk the path on the BSP view to recover
///      the split's first-child leftmost pane id + the total
///      cell dimension along the split axis;
///   3. issue `tmux resize-pane -t <pane> -x|-y <ratio*total>`.
fn apply_set_split_ratio(request_line: &str, id: serde_json::Value) -> String {
    let parsed: serde_json::Value = match serde_json::from_str(request_line) {
        Ok(v) => v,
        Err(e) => {
            return error_envelope(id, translate::INVALID_REQUEST, &e.to_string());
        }
    };
    let params = &parsed["params"];
    let tab_id = params
        .get("tab_id")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("")
        .to_string();
    let ratio = match params.get("ratio").and_then(serde_json::Value::as_f64) {
        Some(r) if (0.0..=1.0).contains(&r) && r.is_finite() => r,
        Some(r) => {
            return error_envelope(
                id,
                translate::INVALID_REQUEST,
                &format!("ratio out of range: {r}"),
            );
        }
        None => {
            return error_envelope(id, translate::INVALID_REQUEST, "missing ratio");
        }
    };
    let path: Vec<bool> = params
        .get("path")
        .and_then(serde_json::Value::as_array)
        .map(|arr| arr.iter().filter_map(|v| v.as_bool()).collect())
        .unwrap_or_default();
    if tab_id.is_empty() {
        return error_envelope(id, translate::INVALID_REQUEST, "missing tab_id");
    }

    // Step 1: read live layout.
    let snapshot = Command::new("tmux")
        .args(["display-message", "-t", &tab_id, "-p", "#{window_layout}"])
        .output();
    let snapshot = match snapshot {
        Ok(o) => o,
        Err(e) => {
            return error_envelope(id, translate::TMUX_FAILED, &format!("spawn tmux: {e}"));
        }
    };
    if !snapshot.status.success() {
        let stderr = String::from_utf8_lossy(&snapshot.stderr);
        let code = classify_tmux_error("layout.snapshot", &stderr);
        return error_envelope(
            id,
            code,
            &format!(
                "display-message exited {}: {}",
                snapshot.status,
                stderr.trim()
            ),
        );
    }
    let layout_str = String::from_utf8_lossy(&snapshot.stdout).trim().to_string();
    if layout_str.is_empty() {
        return error_envelope(
            id,
            translate::TAB_NOT_FOUND,
            "tab not found (empty display-message output)",
        );
    }

    // Step 2: walk path.
    let tree = match parse_layout(&layout_str) {
        Ok(t) => t,
        Err(e) => {
            return error_envelope(
                id,
                translate::INTERNAL_ERROR,
                &format!("parse layout {layout_str:?}: {e}"),
            );
        }
    };
    let Some(target) = walk_split_path(&tree, &path) else {
        return error_envelope(
            id,
            translate::INVALID_REQUEST,
            &format!("path {path:?} doesn't resolve to a split in {layout_str:?}"),
        );
    };

    // Step 3: resize-pane.
    let cells = (ratio * target.total_dim as f64)
        .round()
        .clamp(1.0, u32::MAX as f64) as u32;
    let axis_flag = match target.direction {
        BspSplitDirection::Horizontal => "-x",
        BspSplitDirection::Vertical => "-y",
    };
    let resize = Command::new("tmux")
        .args([
            "resize-pane",
            "-t",
            &target.leftmost_first_pane_id,
            axis_flag,
            &cells.to_string(),
        ])
        .output();
    match resize {
        Ok(o) if o.status.success() => success_envelope(&id, &serde_json::json!({})),
        Ok(o) => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            let code = classify_tmux_error("pane.set_split_ratio", &stderr);
            error_envelope(
                id,
                code,
                &format!("resize-pane exited {}: {}", o.status, stderr.trim()),
            )
        }
        Err(e) => error_envelope(id, translate::TMUX_FAILED, &format!("spawn tmux: {e}")),
    }
}

/// Heuristically map tmux stderr fragments to herdr error
/// codes. `can't find session` -> workspace_not_found, `can't
/// find window/pane` -> tab_not_found / pane_not_found. Falls
/// back to `tmux_failed` for anything else.
fn classify_tmux_error(method: &str, stderr: &str) -> &'static str {
    let s = stderr.to_ascii_lowercase();
    if s.contains("can't find session") || s.contains("no such session") {
        return translate::WORKSPACE_NOT_FOUND;
    }
    if s.contains("can't find window") || s.contains("no such window") {
        return translate::TAB_NOT_FOUND;
    }
    if s.contains("can't find pane") || s.contains("no such pane") {
        return translate::PANE_NOT_FOUND;
    }
    // No tmux server running: every workspace/tab/pane is by
    // definition absent. Probe-time RPCs against an empty
    // host land here, and cmux's probeCapabilities wants to
    // see tab_not_found / workspace_not_found.
    if s.contains("error connecting") || s.contains("no server running") {
        return match method {
            "layout.snapshot" => translate::TAB_NOT_FOUND,
            m if m.starts_with("workspace.") => translate::WORKSPACE_NOT_FOUND,
            m if m.starts_with("pane.") || m.starts_with("panes.") => translate::PANE_NOT_FOUND,
            _ => translate::WORKSPACE_NOT_FOUND,
        };
    }
    // For methods that target specific entities, a generic
    // "can't find" likely means the entity doesn't exist;
    // narrow the code based on what the method targets.
    if s.contains("can't find") {
        return match method {
            m if m.starts_with("workspace.") => translate::WORKSPACE_NOT_FOUND,
            "layout.snapshot" | "tab.reorder" => translate::TAB_NOT_FOUND,
            m if m.starts_with("pane.") || m.starts_with("panes.") => translate::PANE_NOT_FOUND,
            _ => translate::TMUX_FAILED,
        };
    }
    translate::TMUX_FAILED
}

fn run_tmux_and_shape(
    id: serde_json::Value,
    method: &str,
    base_argv: Vec<String>,
    request_line: &str,
) -> String {
    let mut argv = base_argv;
    if let Some(extra) = capture_args_for(method) {
        argv.extend(extra);
    }
    let output = match Command::new("tmux").args(&argv).output() {
        Ok(o) => o,
        Err(e) => return error_envelope(id, translate::TMUX_FAILED, &format!("spawn tmux: {e}")),
    };
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let code = classify_tmux_error(method, &stderr);
        return error_envelope(
            id,
            code,
            &format!("tmux exited {}: {}", output.status, stderr.trim()),
        );
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    // tmux's display-message returns exit 0 with empty stdout
    // when the target window/session doesn't exist. For
    // layout.snapshot specifically, that's how cmux's
    // probeCapabilities expects to detect compatibility.
    if method == "layout.snapshot" && stdout.trim().is_empty() {
        return error_envelope(
            id,
            translate::TAB_NOT_FOUND,
            "tmux display-message returned empty: target window not found",
        );
    }
    let params = serde_json::from_str::<serde_json::Value>(request_line)
        .ok()
        .and_then(|v| v.get("params").cloned())
        .unwrap_or(serde_json::Value::Null);
    match shape_response_with_params(method, id.clone(), &stdout, &params) {
        Ok(resp) => serde_json::to_string(&resp)
            .unwrap_or_else(|e| error_envelope(id, translate::INTERNAL_ERROR, &e.to_string())),
        Err(e) => error_envelope(id, translate::INTERNAL_ERROR, &e.to_string()),
    }
}

fn success_envelope(id: &serde_json::Value, result: &serde_json::Value) -> String {
    serde_json::to_string(&serde_json::json!({"id": id, "result": result}))
        .unwrap_or_else(|e| error_envelope(id.clone(), translate::INTERNAL_ERROR, &e.to_string()))
}

fn error_envelope(id: serde_json::Value, code: &str, message: &str) -> String {
    let resp = ErrorResponse {
        id,
        error: ErrorObject {
            code: code.to_string(),
            message: message.to_string(),
        },
    };
    serde_json::to_string(&resp).unwrap_or_else(|_| {
        format!("{{\"id\":null,\"error\":{{\"code\":\"{code}\",\"message\":\"serialize error\"}}}}")
    })
}
