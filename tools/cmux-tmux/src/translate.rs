use serde::{Deserialize, Serialize};
use serde_json::Value;
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TranslateOutcome {
    RunTmux(Vec<String>),
    ImmediateResponse(ResultResponse),
    RunMulti(Vec<Vec<String>>),
}

pub fn translate_request(json: &str) -> Result<TranslateOutcome, TranslateError> {
    let req: Request = serde_json::from_str(json)?;
    match req.method.as_str() {
        "ping" => Ok(TranslateOutcome::ImmediateResponse(ResultResponse {
            id: req.id,
            result: Value::String("pong".into()),
        })),
        "pane.split" => translate_pane_split(&req.params).map(TranslateOutcome::RunTmux),
        "panes.list" => translate_panes_list(&req.params).map(TranslateOutcome::RunTmux),
        "workspace.list" => Ok(TranslateOutcome::RunTmux(translate_workspace_list())),
        other => Err(TranslateError::UnsupportedMethod(other.to_string())),
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
    }
}

const PANE_FORMAT: &str = "#{pane_id}\t#{pane_active}\t#{pane_width}\t#{pane_height}";
const SESSION_FORMAT: &str = "#{session_id}\t#{session_name}\t#{session_attached}";

fn translate_workspace_list() -> Vec<String> {
    vec!["list-sessions".into(), "-F".into(), SESSION_FORMAT.into()]
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
