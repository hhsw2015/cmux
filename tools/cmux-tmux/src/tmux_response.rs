//! Pure helpers that turn tmux stdout into CPP response
//! envelopes, plus the per-method capture-arg map used by the
//! bin to enrich an argv with `-P -F '#{...}'` so the shim can
//! recover newly-created ids.

use serde_json::Value;

use crate::parse::CppEvent;
use crate::translate::ResultResponse;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShapeError {
    pub message: String,
}

impl std::fmt::Display for ShapeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for ShapeError {}

/// Encode a parsed [`CppEvent`] as the JSON notification line
/// the bin writes to stdout. The wire shape is `{event, data}`;
/// cmux's `HerdrApiClient.handleData` keys on those exact
/// fields. Notifications carry no `id` so clients can
/// distinguish them from RPC responses.
///
/// Event names mirror herdr's: dotted (`layout.changed`,
/// `pane.exited`, `workspace.closed`, `tab.reordered`).
pub fn event_to_json(ev: &CppEvent) -> Value {
    match ev {
        CppEvent::LayoutChanged {
            window_id,
            layout_string,
        } => serde_json::json!({
            "event": "layout.changed",
            "data": {
                "window_id": window_id,
                "layout_string": layout_string,
            },
        }),
        CppEvent::PaneExited { pane_id } => serde_json::json!({
            "event": "pane.exited",
            "data": { "pane_id": pane_id },
        }),
        CppEvent::WorkspaceClosed { workspace_id } => serde_json::json!({
            "event": "workspace.closed",
            "data": { "workspace_id": workspace_id },
        }),
    }
}

/// Extra argv suffix to append to the translate-emitted argv for
/// methods whose response carries a freshly-created id. Returns
/// `None` for methods that don't need post-capture.
pub fn capture_args_for(method: &str) -> Option<Vec<String>> {
    match method {
        "workspace.create" => Some(vec!["-P".into(), "-F".into(), "#{session_id}".into()]),
        "pane.split" => Some(vec!["-P".into(), "-F".into(), "#{pane_id}".into()]),
        _ => None,
    }
}

/// Build a CPP result envelope from a tmux command's stdout.
/// Convenience wrapper for methods that don't need request
/// params; defers to [`shape_response_with_params`].
pub fn shape_response(method: &str, id: Value, stdout: &str) -> Result<ResultResponse, ShapeError> {
    shape_response_with_params(method, id, stdout, &Value::Null)
}

/// Like [`shape_response`] but the shaper can also see the
/// original request params. Needed by methods whose response
/// echoes a request-side value (e.g. `workspace.attach` puts
/// `workspace_id` from params next to the panes from stdout).
pub fn shape_response_with_params(
    method: &str,
    id: Value,
    stdout: &str,
    params: &Value,
) -> Result<ResultResponse, ShapeError> {
    let trimmed = stdout.trim_end_matches(['\r', '\n']);
    let result = match method {
        "workspace.attach" => {
            let workspace_id = params
                .get("workspace_id")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let panes = parse_pane_lines(trimmed)?;
            serde_json::json!({
                "workspace_id": workspace_id,
                "panes": panes,
            })
        }
        "workspace.create" => {
            let session_id = trimmed.trim();
            if session_id.is_empty() {
                return Err(ShapeError {
                    message: "workspace.create stdout was empty".into(),
                });
            }
            serde_json::json!({ "workspace_id": session_id })
        }
        "pane.split" => {
            let pane_id = trimmed.trim();
            if pane_id.is_empty() {
                return Err(ShapeError {
                    message: "pane.split stdout was empty".into(),
                });
            }
            serde_json::json!({ "pane_id": pane_id })
        }
        "panes.list" => Value::Object(
            [("panes".into(), Value::Array(parse_pane_lines(trimmed)?))]
                .into_iter()
                .collect(),
        ),
        "workspace.list" => Value::Object(
            [(
                "workspaces".into(),
                Value::Array(parse_session_lines(trimmed)?),
            )]
            .into_iter()
            .collect(),
        ),
        // cmux's HerdrApiClient.handleData reads `result as?
        // [String: Any]`; non-dict results are dropped silently.
        // For methods with no useful payload we return an empty
        // object — same effect as a "void return" RPC.
        _ => Value::Object(serde_json::Map::new()),
    };
    Ok(ResultResponse { id, result })
}

fn parse_pane_lines(stdout: &str) -> Result<Vec<Value>, ShapeError> {
    if stdout.trim().is_empty() {
        return Ok(Vec::new());
    }
    stdout
        .lines()
        .map(|line| {
            let mut fields = line.split('\t');
            let pane_id = next_field(&mut fields, "pane_id")?;
            let active_raw = next_field(&mut fields, "pane_active")?;
            let cols = parse_u32(&mut fields, "pane_width")?;
            let rows = parse_u32(&mut fields, "pane_height")?;
            Ok(serde_json::json!({
                "pane_id": pane_id,
                "active": active_raw == "1",
                "cols": cols,
                "rows": rows,
            }))
        })
        .collect()
}

fn parse_session_lines(stdout: &str) -> Result<Vec<Value>, ShapeError> {
    if stdout.trim().is_empty() {
        return Ok(Vec::new());
    }
    stdout
        .lines()
        .map(|line| {
            let mut fields = line.split('\t');
            let workspace_id = next_field(&mut fields, "session_id")?;
            let name = next_field(&mut fields, "session_name")?;
            let attached_raw = next_field(&mut fields, "session_attached")?;
            Ok(serde_json::json!({
                "workspace_id": workspace_id,
                "name": name,
                "attached": attached_raw == "1",
            }))
        })
        .collect()
}

fn next_field<'a>(
    fields: &mut std::str::Split<'a, char>,
    name: &'static str,
) -> Result<&'a str, ShapeError> {
    fields.next().ok_or_else(|| ShapeError {
        message: format!("missing field {name}"),
    })
}

fn parse_u32(
    fields: &mut std::str::Split<'_, char>,
    name: &'static str,
) -> Result<u32, ShapeError> {
    let raw = next_field(fields, name)?;
    raw.parse::<u32>().map_err(|e| ShapeError {
        message: format!("bad {name}: {e}"),
    })
}
