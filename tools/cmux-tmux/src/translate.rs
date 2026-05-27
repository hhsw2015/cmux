use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::fmt;

#[derive(Debug)]
pub enum TranslateError {
    InvalidJson(serde_json::Error),
    UnsupportedMethod(String),
    MissingField(&'static str),
    InvalidField(&'static str, String),
}

impl fmt::Display for TranslateError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidJson(e) => write!(f, "invalid json: {e}"),
            Self::UnsupportedMethod(m) => write!(f, "unsupported method: {m}"),
            Self::MissingField(name) => write!(f, "missing field: {name}"),
            Self::InvalidField(name, value) => write!(f, "invalid field {name}: {value}"),
        }
    }
}

impl std::error::Error for TranslateError {}

impl From<serde_json::Error> for TranslateError {
    fn from(e: serde_json::Error) -> Self {
        Self::InvalidJson(e)
    }
}

#[derive(Debug, Deserialize)]
struct Request {
    id: Value,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ResultResponse {
    pub id: Value,
    pub result: Value,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ErrorObject {
    /// herdr-side error codes are strings ("tab_not_found",
    /// "workspace_not_found", "method_not_found", ...). cmux's
    /// HerdrApiError.code is `String`; we mirror that exactly.
    pub code: String,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ErrorResponse {
    pub id: Value,
    pub error: ErrorObject,
}

/// herdr error code strings (subset). cmux's `HerdrBackend.probe`
/// switches on `tab_not_found` / `workspace_not_found` to mark a
/// daemon as compatible.
pub const METHOD_NOT_FOUND: &str = "method_not_found";
pub const INVALID_REQUEST: &str = "invalid_request";
pub const TAB_NOT_FOUND: &str = "tab_not_found";
pub const WORKSPACE_NOT_FOUND: &str = "workspace_not_found";
pub const PANE_NOT_FOUND: &str = "pane_not_found";
pub const TMUX_FAILED: &str = "tmux_failed";
pub const INTERNAL_ERROR: &str = "internal_error";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TranslateOutcome {
    RunTmux(Vec<String>),
    ImmediateResponse(ResultResponse),
    ImmediateError(ErrorResponse),
    RunMulti(Vec<Vec<String>>),
}

/// Pane-keyed snapshot of the data translate needs from the
/// current workspace. Today only `split_geometry` is populated:
/// for each pane we know its parent split's axis (`'h'` or `'v'`)
/// and the total cell length along that axis. Future fields
/// (cwd, command, etc.) get added when their first test demands
/// them.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TranslateContext {
    pub split_geometry: HashMap<String, (char, u32)>,
}

pub fn translate_request(json: &str) -> Result<TranslateOutcome, TranslateError> {
    translate_request_in_context(json, &TranslateContext::default())
}

pub fn translate_request_in_context(
    json: &str,
    _ctx: &TranslateContext,
) -> Result<TranslateOutcome, TranslateError> {
    let req: Request = serde_json::from_str(json)?;
    match req.method.as_str() {
        "ping" => Ok(TranslateOutcome::ImmediateResponse(ResultResponse {
            id: req.id,
            result: serde_json::json!({
                "version": env!("CARGO_PKG_VERSION"),
                "protocol": 1,
            }),
        })),
        "events.subscribe" => Ok(TranslateOutcome::ImmediateResponse(ResultResponse {
            id: req.id,
            result: serde_json::json!({ "subscribed": true }),
        })),
        "pane.split" => translate_pane_split(&req.params).map(TranslateOutcome::RunTmux),
        "panes.list" => translate_panes_list(&req.params).map(TranslateOutcome::RunTmux),
        "workspace.list" => Ok(TranslateOutcome::RunTmux(translate_workspace_list())),
        "workspace.create" => {
            translate_workspace_create(&req.params).map(TranslateOutcome::RunTmux)
        }
        "workspace.attach" => translate_panes_list(&req.params).map(TranslateOutcome::RunTmux),
        "workspace.close" => {
            translate_workspace_target("kill-session", &req.params).map(TranslateOutcome::RunTmux)
        }
        "workspace.rename" => {
            translate_workspace_rename(&req.params).map(TranslateOutcome::RunTmux)
        }
        "layout.snapshot" => translate_layout_snapshot(&req.params).map(TranslateOutcome::RunTmux),
        "pane.swap" => translate_pane_swap(&req.params).map(TranslateOutcome::RunTmux),
        "tab.list" => translate_tab_list(&req.params).map(TranslateOutcome::RunTmux),
        "tab.focus" => translate_tab_focus(&req.params).map(TranslateOutcome::RunTmux),
        "tab.create" => translate_tab_create(&req.params).map(TranslateOutcome::RunTmux),
        "tab.close" => translate_tab_close(&req.params).map(TranslateOutcome::RunTmux),
        "tab.rename" => translate_tab_rename(&req.params).map(TranslateOutcome::RunTmux),
        "workspace.focus" => {
            translate_workspace_target("switch-client", &req.params).map(TranslateOutcome::RunTmux)
        }
        // tab.reorder is a no-op stub today: tmux's
        // move-window-by-index requires a temporary "park"
        // sweep to avoid index collisions, which is fragile
        // enough that I'd rather punt than ship a half-broken
        // version. cmux gets a successful response so the UI
        // doesn't error; the next reattach will show whatever
        // order tmux had. See PLAN.md known-loss list.
        "tab.reorder" => Ok(TranslateOutcome::ImmediateResponse(ResultResponse {
            id: req.id,
            result: serde_json::json!({}),
        })),
        "pane.resize" => translate_pane_resize(&req.params).map(TranslateOutcome::RunTmux),
        "pane.focus" => {
            translate_single_pane_target("select-pane", &req.params).map(TranslateOutcome::RunTmux)
        }
        "pane.close" => {
            translate_single_pane_target("kill-pane", &req.params).map(TranslateOutcome::RunTmux)
        }
        // pane.set_split_ratio is special-cased in the bin: it
        // needs a multi-step orchestration (read layout, walk
        // path, issue resize-pane). Translate doesn't see it.
        other => Ok(TranslateOutcome::ImmediateError(ErrorResponse {
            id: req.id,
            error: ErrorObject {
                code: METHOD_NOT_FOUND.to_string(),
                message: format!("Method not found: {other}"),
            },
        })),
    }
}

pub fn request_json_to_tmux_argv(json: &str) -> Result<Vec<String>, TranslateError> {
    match translate_request(json)? {
        TranslateOutcome::RunTmux(argv) => Ok(argv),
        TranslateOutcome::RunMulti(_) => Err(TranslateError::UnsupportedMethod(
            "multi-step request".into(),
        )),
        TranslateOutcome::ImmediateResponse(_) => Err(TranslateError::UnsupportedMethod(
            "immediate-response request has no tmux argv".into(),
        )),
        TranslateOutcome::ImmediateError(err) => {
            Err(TranslateError::UnsupportedMethod(err.error.message))
        }
    }
}

const PANE_FORMAT: &str = "#{pane_id}\t#{pane_active}\t#{pane_width}\t#{pane_height}";
const SESSION_FORMAT: &str = "#{session_id}\t#{session_name}\t#{session_attached}";

fn translate_workspace_list() -> Vec<String> {
    vec!["list-sessions".into(), "-F".into(), SESSION_FORMAT.into()]
}

/// `layout.snapshot` reads `#{window_layout}` plus the active
/// pane id of the targeted window. The bin parses the result.
/// `tab_id` is the tmux window id (e.g. `@0`); a non-existent
/// target returns empty stdout, which the bin maps to a
/// `tab_not_found` error envelope.
fn translate_layout_snapshot(params: &Value) -> Result<Vec<String>, TranslateError> {
    let tab_id = params
        .get("tab_id")
        .and_then(Value::as_str)
        .ok_or(TranslateError::MissingField("tab_id"))?;
    Ok(vec![
        "display-message".into(),
        "-t".into(),
        tab_id.into(),
        "-p".into(),
        // Tab is a literal 0x09 in the format string; tmux
        // forwards it verbatim. Single-format string keeps the
        // shaper's split logic simple.
        "#{window_layout}\t#{pane_id}".into(),
    ])
}

fn translate_pane_swap(params: &Value) -> Result<Vec<String>, TranslateError> {
    let a = params
        .get("a_pane_id")
        .and_then(Value::as_str)
        .ok_or(TranslateError::MissingField("a_pane_id"))?;
    let b = params
        .get("b_pane_id")
        .and_then(Value::as_str)
        .ok_or(TranslateError::MissingField("b_pane_id"))?;
    Ok(vec![
        "swap-pane".into(),
        "-s".into(),
        a.into(),
        "-t".into(),
        b.into(),
    ])
}

const WINDOW_FORMAT: &str = "#{window_id}\t#{window_index}\t#{window_name}\t#{window_active}";

fn translate_tab_list(params: &Value) -> Result<Vec<String>, TranslateError> {
    let workspace_id = params
        .get("workspace_id")
        .and_then(Value::as_str)
        .ok_or(TranslateError::MissingField("workspace_id"))?;
    Ok(vec![
        "list-windows".into(),
        "-t".into(),
        workspace_id.into(),
        "-F".into(),
        WINDOW_FORMAT.into(),
    ])
}

fn translate_tab_focus(params: &Value) -> Result<Vec<String>, TranslateError> {
    let tab_id = params
        .get("tab_id")
        .and_then(Value::as_str)
        .ok_or(TranslateError::MissingField("tab_id"))?;
    Ok(vec!["select-window".into(), "-t".into(), tab_id.into()])
}

fn translate_tab_create(params: &Value) -> Result<Vec<String>, TranslateError> {
    let workspace_id = params
        .get("workspace_id")
        .and_then(Value::as_str)
        .ok_or(TranslateError::MissingField("workspace_id"))?;
    let mut argv: Vec<String> = vec![
        "new-window".into(),
        "-t".into(),
        workspace_id.into(),
        "-P".into(),
        "-F".into(),
        WINDOW_FORMAT.into(),
    ];
    if let Some(name) = params.get("name").and_then(Value::as_str) {
        argv.extend(["-n".into(), name.into()]);
    }
    if let Some(cwd) = params.get("cwd").and_then(Value::as_str) {
        argv.extend(["-c".into(), cwd.into()]);
    }
    if let Some(focus) = params.get("focus").and_then(Value::as_bool) {
        if !focus {
            // tmux accepts flags in any order; push so reordering the
            // constructor above doesn't shift -d into the wrong slot.
            argv.push("-d".into());
        }
    }
    Ok(argv)
}

fn translate_tab_close(params: &Value) -> Result<Vec<String>, TranslateError> {
    let tab_id = params
        .get("tab_id")
        .and_then(Value::as_str)
        .ok_or(TranslateError::MissingField("tab_id"))?;
    Ok(vec!["kill-window".into(), "-t".into(), tab_id.into()])
}

fn translate_tab_rename(params: &Value) -> Result<Vec<String>, TranslateError> {
    let tab_id = params
        .get("tab_id")
        .and_then(Value::as_str)
        .ok_or(TranslateError::MissingField("tab_id"))?;
    let name = params
        .get("name")
        .and_then(Value::as_str)
        .ok_or(TranslateError::MissingField("name"))?;
    Ok(vec![
        "rename-window".into(),
        "-t".into(),
        tab_id.into(),
        name.into(),
    ])
}

fn translate_workspace_target(verb: &str, params: &Value) -> Result<Vec<String>, TranslateError> {
    let workspace_id = params
        .get("workspace_id")
        .and_then(Value::as_str)
        .ok_or(TranslateError::MissingField("workspace_id"))?;
    Ok(vec![verb.into(), "-t".into(), workspace_id.into()])
}

fn translate_workspace_rename(params: &Value) -> Result<Vec<String>, TranslateError> {
    let workspace_id = params
        .get("workspace_id")
        .and_then(Value::as_str)
        .ok_or(TranslateError::MissingField("workspace_id"))?;
    let name = params
        .get("name")
        .and_then(Value::as_str)
        .ok_or(TranslateError::MissingField("name"))?;
    Ok(vec![
        "rename-session".into(),
        "-t".into(),
        workspace_id.into(),
        name.into(),
    ])
}

fn translate_workspace_create(params: &Value) -> Result<Vec<String>, TranslateError> {
    let mut argv: Vec<String> = vec!["new-session".into(), "-d".into()];
    if let Some(name) = params.get("name").and_then(Value::as_str) {
        argv.push("-s".into());
        argv.push(name.into());
    }
    if let Some(cwd) = params.get("cwd").and_then(Value::as_str) {
        argv.push("-c".into());
        argv.push(cwd.into());
    }
    Ok(argv)
}

fn translate_panes_list(params: &Value) -> Result<Vec<String>, TranslateError> {
    let workspace_id = params
        .get("workspace_id")
        .and_then(Value::as_str)
        .ok_or(TranslateError::MissingField("workspace_id"))?;
    Ok(vec![
        "list-panes".into(),
        "-t".into(),
        workspace_id.into(),
        "-F".into(),
        PANE_FORMAT.into(),
    ])
}

fn translate_single_pane_target(verb: &str, params: &Value) -> Result<Vec<String>, TranslateError> {
    // cmux/herdr field name is `pane_id`. We accept the legacy
    // `target_pane_id` as a fallback to keep the older internal
    // tests + any pre-rename callers working through the
    // transition.
    let target = params
        .get("pane_id")
        .or_else(|| params.get("target_pane_id"))
        .and_then(Value::as_str)
        .ok_or(TranslateError::MissingField("pane_id"))?;
    Ok(vec![verb.into(), "-t".into(), target.into()])
}

fn translate_pane_resize(params: &Value) -> Result<Vec<String>, TranslateError> {
    let target = params
        .get("target_pane_id")
        .and_then(Value::as_str)
        .ok_or(TranslateError::MissingField("target_pane_id"))?;
    let cols = params
        .get("cols")
        .and_then(Value::as_u64)
        .ok_or(TranslateError::MissingField("cols"))?;
    let rows = params
        .get("rows")
        .and_then(Value::as_u64)
        .ok_or(TranslateError::MissingField("rows"))?;
    Ok(vec![
        "resize-pane".into(),
        "-t".into(),
        target.into(),
        "-x".into(),
        cols.to_string(),
        "-y".into(),
        rows.to_string(),
    ])
}

fn translate_pane_split(params: &Value) -> Result<Vec<String>, TranslateError> {
    let target = params
        .get("target_pane_id")
        .and_then(Value::as_str)
        .ok_or(TranslateError::MissingField("target_pane_id"))?;
    let direction = params
        .get("direction")
        .and_then(Value::as_str)
        .ok_or(TranslateError::MissingField("direction"))?;
    let flag = match direction {
        "right" | "left" => "-h",
        "down" | "up" => "-v",
        other => return Err(TranslateError::InvalidField("direction", other.to_string())),
    };

    let mut argv: Vec<String> = vec!["split-window".into(), flag.into()];
    if let Some(cwd) = params.get("cwd").and_then(Value::as_str) {
        argv.push("-c".into());
        argv.push(cwd.into());
    }
    argv.push("-t".into());
    argv.push(target.into());
    Ok(argv)
}

#[cfg(test)]
mod tab_translator_tests {
    use super::*;
    use serde_json::json;

    fn outcome_to_argv(json_str: &str) -> Vec<String> {
        match translate_request(json_str).expect("translate ok") {
            TranslateOutcome::RunTmux(argv) => argv,
            other => panic!("expected RunTmux, got {:?}", std::mem::discriminant(&other)),
        }
    }

    #[test]
    fn tab_create_default_focus_omits_d_flag() {
        let req = json!({
            "id": "1",
            "method": "tab.create",
            "params": {"workspace_id": "$0"}
        });
        let argv = outcome_to_argv(&req.to_string());
        assert_eq!(argv[0], "new-window");
        assert!(argv.iter().any(|a| a == "-t"));
        assert!(argv.iter().any(|a| a == "$0"));
        assert!(argv.iter().any(|a| a == "-P"));
        assert!(!argv.iter().any(|a| a == "-d"), "default focus should not pass -d, got {:?}", argv);
    }

    #[test]
    fn tab_create_focus_false_appends_d_flag() {
        let req = json!({
            "id": "1",
            "method": "tab.create",
            "params": {"workspace_id": "$0", "focus": false}
        });
        let argv = outcome_to_argv(&req.to_string());
        assert!(argv.iter().any(|a| a == "-d"), "focus=false must add -d, got {:?}", argv);
    }

    #[test]
    fn tab_create_with_name_and_cwd() {
        let req = json!({
            "id": "1",
            "method": "tab.create",
            "params": {
                "workspace_id": "$0",
                "name": "demo",
                "cwd": "/tmp"
            }
        });
        let argv = outcome_to_argv(&req.to_string());
        let n_idx = argv.iter().position(|a| a == "-n").expect("-n present");
        assert_eq!(argv[n_idx + 1], "demo");
        let c_idx = argv.iter().position(|a| a == "-c").expect("-c present");
        assert_eq!(argv[c_idx + 1], "/tmp");
    }

    #[test]
    fn tab_close_uses_kill_window() {
        let req = json!({
            "id": "1",
            "method": "tab.close",
            "params": {"workspace_id": "$0", "tab_id": "@5"}
        });
        let argv = outcome_to_argv(&req.to_string());
        assert_eq!(argv, vec!["kill-window", "-t", "@5"]);
    }

    #[test]
    fn tab_rename_uses_rename_window() {
        let req = json!({
            "id": "1",
            "method": "tab.rename",
            "params": {"tab_id": "@7", "name": "new-name"}
        });
        let argv = outcome_to_argv(&req.to_string());
        assert_eq!(argv, vec!["rename-window", "-t", "@7", "new-name"]);
    }
}
