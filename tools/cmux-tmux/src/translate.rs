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
    pub code: i32,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ErrorResponse {
    pub id: Value,
    pub error: ErrorObject,
}

/// JSON-RPC 2.0 error code for method-not-found.
pub const METHOD_NOT_FOUND: i32 = -32601;

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
    ctx: &TranslateContext,
) -> Result<TranslateOutcome, TranslateError> {
    let req: Request = serde_json::from_str(json)?;
    match req.method.as_str() {
        "ping" => Ok(TranslateOutcome::ImmediateResponse(ResultResponse {
            id: req.id,
            result: Value::String("pong".into()),
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
        "pane.resize" => translate_pane_resize(&req.params).map(TranslateOutcome::RunTmux),
        "pane.focus" => {
            translate_single_pane_target("select-pane", &req.params).map(TranslateOutcome::RunTmux)
        }
        "pane.close" => {
            translate_single_pane_target("kill-pane", &req.params).map(TranslateOutcome::RunTmux)
        }
        "pane.set_split_ratio" => {
            translate_set_split_ratio(&req.params, ctx).map(TranslateOutcome::RunTmux)
        }
        other => Ok(TranslateOutcome::ImmediateError(ErrorResponse {
            id: req.id,
            error: ErrorObject {
                code: METHOD_NOT_FOUND,
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

fn translate_set_split_ratio(
    params: &Value,
    ctx: &TranslateContext,
) -> Result<Vec<String>, TranslateError> {
    let target = params
        .get("target_pane_id")
        .and_then(Value::as_str)
        .ok_or(TranslateError::MissingField("target_pane_id"))?;
    let ratio = params
        .get("ratio")
        .and_then(Value::as_f64)
        .ok_or(TranslateError::MissingField("ratio"))?;
    if !ratio.is_finite() || !(0.0..=1.0).contains(&ratio) {
        return Err(TranslateError::InvalidField("ratio", ratio.to_string()));
    }
    let (axis, total) = ctx
        .split_geometry
        .get(target)
        .copied()
        .ok_or(TranslateError::MissingField("split_geometry"))?;
    let cells = (ratio * total as f64).round() as u32;
    let axis_flag = match axis {
        'h' => "-x",
        'v' => "-y",
        other => return Err(TranslateError::InvalidField("axis", other.to_string())),
    };
    Ok(vec![
        "resize-pane".into(),
        "-t".into(),
        target.into(),
        axis_flag.into(),
        cells.to_string(),
    ])
}

fn translate_single_pane_target(verb: &str, params: &Value) -> Result<Vec<String>, TranslateError> {
    let target = params
        .get("target_pane_id")
        .and_then(Value::as_str)
        .ok_or(TranslateError::MissingField("target_pane_id"))?;
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
