//! cmux-tmux entry point. The bin is the only place that does
//! I/O. All translation / parsing lives in the lib.
//!
//! Subcommands:
//!
//! * `serve` — line-delimited JSON-RPC on stdin/stdout. Used as
//!   the cmux pane protocol (CPP) endpoint. Today only methods
//!   with an `ImmediateResponse` translation (e.g. `ping`) work
//!   end to end; tmux-backed methods will land in I1+.
//! * `raw-pty-attach` — to be implemented in stage 4.

use std::io::{self, BufRead, Write};
use std::process::Command;

use cmux_tmux::tmux_response::{capture_args_for, shape_response};
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

fn serve() -> i32 {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut out = stdout.lock();
    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(e) => {
                let _ = writeln!(
                    out,
                    "{}",
                    error_envelope(serde_json::Value::Null, INTERNAL_ERROR, &e.to_string())
                );
                let _ = out.flush();
                return 1;
            }
        };
        if line.trim().is_empty() {
            continue;
        }

        let response = handle_line(&line);
        if writeln!(out, "{response}").is_err() {
            return 1;
        }
        if out.flush().is_err() {
            return 1;
        }
    }
    0
}

fn handle_line(line: &str) -> String {
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
        Ok(TranslateOutcome::RunTmux(argv)) => {
            let id = parse_id(line);
            let method = parse_method(line);
            run_tmux_and_shape(id, &method, argv)
        }
        Ok(TranslateOutcome::RunMulti(_)) => {
            let id = parse_id(line);
            error_envelope(id, INTERNAL_ERROR, "multi-step requests not yet wired")
        }
        Err(TranslateError::InvalidJson(e)) => {
            error_envelope(serde_json::Value::Null, PARSE_ERROR, &e.to_string())
        }
        Err(other) => {
            let id = parse_id(line);
            error_envelope(id, INTERNAL_ERROR, &other.to_string())
        }
    }
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
