use serde::Deserialize;
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
    #[allow(dead_code)]
    id: Value,
    method: String,
    #[serde(default)]
    params: Value,
}

pub fn request_json_to_tmux_argv(json: &str) -> Result<Vec<String>, TranslateError> {
    let req: Request = serde_json::from_str(json)?;
    match req.method.as_str() {
        "pane.split" => translate_pane_split(&req.params),
        other => Err(TranslateError::UnsupportedMethod(other.to_string())),
    }
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
