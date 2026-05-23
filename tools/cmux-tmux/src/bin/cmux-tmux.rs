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

use std::io::{self, BufRead, BufReader, Write};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};

use cmux_tmux::parse::Session;
use cmux_tmux::tmux_response::{capture_args_for, event_to_json, shape_response};
use cmux_tmux::translate::{
    translate_request, ErrorObject, ErrorResponse, TranslateError, TranslateOutcome,
};

const INTERNAL_ERROR: i32 = -32603;
const PARSE_ERROR: i32 = -32700;
const TMUX_ERROR: i32 = -32000;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let exit = match args.first().map(String::as_str) {
        Some("serve") => serve(),
        Some(other) => {
            eprintln!("unknown subcommand: {other}");
            2
        }
        None => {
            eprintln!("usage: cmux-tmux serve");
            2
        }
    };
    std::process::exit(exit);
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
                    INTERNAL_ERROR,
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

    match translate_request(line) {
        Ok(TranslateOutcome::ImmediateResponse(r)) => {
            serde_json::to_string(&r).unwrap_or_else(|e| {
                error_envelope(serde_json::Value::Null, INTERNAL_ERROR, &e.to_string())
            })
        }
        Ok(TranslateOutcome::ImmediateError(e)) => {
            serde_json::to_string(&e).unwrap_or_else(|err| {
                error_envelope(serde_json::Value::Null, INTERNAL_ERROR, &err.to_string())
            })
        }
        Ok(TranslateOutcome::RunTmux(argv)) => run_tmux_and_shape(id, &method, argv),
        Ok(TranslateOutcome::RunMulti(_)) => {
            error_envelope(id, INTERNAL_ERROR, "multi-step requests not yet wired")
        }
        Err(TranslateError::InvalidJson(e)) => {
            error_envelope(serde_json::Value::Null, PARSE_ERROR, &e.to_string())
        }
        Err(other) => error_envelope(id, INTERNAL_ERROR, &other.to_string()),
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
        return error_envelope(id, INTERNAL_ERROR, "events.subscribe requires workspace_id");
    };

    let mut guard = control.lock().expect("control mutex");
    if guard.is_some() {
        // Already subscribed; idempotent ack.
        return success_envelope(&id, &serde_json::json!({"subscribed": true}));
    }

    let child = match spawn_control_client(&workspace_id, writer.clone()) {
        Ok(c) => c,
        Err(e) => return error_envelope(id, TMUX_ERROR, &format!("spawn tmux -C: {e}")),
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

fn run_tmux_and_shape(id: serde_json::Value, method: &str, base_argv: Vec<String>) -> String {
    let mut argv = base_argv;
    if let Some(extra) = capture_args_for(method) {
        argv.extend(extra);
    }
    let output = match Command::new("tmux").args(&argv).output() {
        Ok(o) => o,
        Err(e) => return error_envelope(id, TMUX_ERROR, &format!("spawn tmux: {e}")),
    };
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return error_envelope(
            id,
            TMUX_ERROR,
            &format!("tmux exited {}: {}", output.status, stderr.trim()),
        );
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    match shape_response(method, id.clone(), &stdout) {
        Ok(resp) => serde_json::to_string(&resp)
            .unwrap_or_else(|e| error_envelope(id, INTERNAL_ERROR, &e.to_string())),
        Err(e) => error_envelope(id, INTERNAL_ERROR, &e.to_string()),
    }
}

fn success_envelope(id: &serde_json::Value, result: &serde_json::Value) -> String {
    serde_json::to_string(&serde_json::json!({"id": id, "result": result}))
        .unwrap_or_else(|e| error_envelope(id.clone(), INTERNAL_ERROR, &e.to_string()))
}

fn error_envelope(id: serde_json::Value, code: i32, message: &str) -> String {
    let resp = ErrorResponse {
        id,
        error: ErrorObject {
            code,
            message: message.to_string(),
        },
    };
    serde_json::to_string(&resp).unwrap_or_else(|_| {
        format!("{{\"id\":null,\"error\":{{\"code\":{code},\"message\":\"serialize error\"}}}}")
    })
}
