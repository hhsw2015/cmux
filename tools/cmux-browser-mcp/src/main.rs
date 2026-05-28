//! MCP stdio server that forwards every browser.* tool call to the running
//! cmux app's Unix domain socket.
//!
//! Why a translator instead of native MCP in cmux: cmux already implements
//! 91 browser.* socket methods (Playwright-like surface — click, fill, eval,
//! screenshot, etc.). Re-implementing them inside an MCP server would
//! duplicate the logic and drift over time. This binary is therefore a
//! one-to-one bridge:
//!
//!   agent <--MCP stdio--> cmux-browser-mcp <--JSON line UDS--> cmux app
//!
//! The MCP `tools/list` is generated from a static manifest below; the
//! `tools/call` handler line-encodes the params, sends them to cmux, and
//! returns the response result as the MCP tool result. There is no
//! per-tool logic in this binary.
//!
//! Socket path resolution mirrors the cmux Python test client: respect
//! CMUX_SOCKET_PATH if set, otherwise fall back to the stable
//! ~/Library/Application Support/cmux/com.cmuxterm.app.sock path, then to a
//! `last-socket-path` marker if either is unreachable.

use std::env;
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

const PROTOCOL_VERSION: &str = "2024-11-05";
const SERVER_NAME: &str = "cmux-browser-mcp";
const SERVER_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Deserialize)]
struct McpRequest {
    #[allow(dead_code)]
    jsonrpc: Option<String>,
    id: Option<Value>,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Debug, Serialize)]
struct McpResponse {
    jsonrpc: &'static str,
    id: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<McpError>,
}

#[derive(Debug, Serialize)]
struct McpError {
    code: i32,
    message: String,
}

fn main() -> io::Result<()> {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut stdout_lock = stdout.lock();

    // Lazy: defer connect until first tool call so the MCP server can answer
    // initialize / tools/list even if cmux isn't running yet.
    let socket: Mutex<Option<SocketBridge>> = Mutex::new(None);

    for line in BufReader::new(stdin.lock()).lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let req: McpRequest = match serde_json::from_str(&line) {
            Ok(req) => req,
            Err(e) => {
                eprintln!("cmux-browser-mcp: invalid request line: {e}");
                continue;
            }
        };

        let id = req.id.clone().unwrap_or(Value::Null);
        let response = handle(&req, &socket, id.clone());
        if req.id.is_none() {
            // Notifications get no response.
            continue;
        }
        let line = serde_json::to_string(&response).unwrap();
        writeln!(stdout_lock, "{}", line)?;
        stdout_lock.flush()?;
    }
    Ok(())
}

fn handle(req: &McpRequest, socket: &Mutex<Option<SocketBridge>>, id: Value) -> McpResponse {
    match req.method.as_str() {
        "initialize" => McpResponse {
            jsonrpc: "2.0",
            id,
            result: Some(json!({
                "protocolVersion": PROTOCOL_VERSION,
                "serverInfo": {
                    "name": SERVER_NAME,
                    "version": SERVER_VERSION
                },
                "capabilities": { "tools": {} }
            })),
            error: None,
        },
        "tools/list" => McpResponse {
            jsonrpc: "2.0",
            id,
            result: Some(json!({ "tools": tools_manifest() })),
            error: None,
        },
        "tools/call" => match call_tool(req, socket) {
            Ok(value) => McpResponse {
                jsonrpc: "2.0",
                id,
                result: Some(value),
                error: None,
            },
            Err(message) => McpResponse {
                jsonrpc: "2.0",
                id,
                result: None,
                error: Some(McpError { code: -32000, message }),
            },
        },
        "ping" => McpResponse {
            jsonrpc: "2.0",
            id,
            result: Some(json!({})),
            error: None,
        },
        other => McpResponse {
            jsonrpc: "2.0",
            id,
            result: None,
            error: Some(McpError {
                code: -32601,
                message: format!("method not found: {other}"),
            }),
        },
    }
}

fn call_tool(req: &McpRequest, socket: &Mutex<Option<SocketBridge>>) -> Result<Value, String> {
    let name = req
        .params
        .get("name")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "missing tool name".to_string())?;
    let cmux_method = mcp_to_cmux_method(name)
        .ok_or_else(|| format!("unknown tool '{name}'"))?;
    let arguments = req
        .params
        .get("arguments")
        .cloned()
        .unwrap_or_else(|| json!({}));

    let mut guard = socket.lock().map_err(|e| format!("socket lock: {e}"))?;
    if guard.is_none() {
        *guard = Some(SocketBridge::connect().map_err(|e| format!("connect cmux socket: {e}"))?);
    }
    let sock = guard.as_mut().expect("connected");
    let result = sock.call(cmux_method, arguments)?;
    Ok(json!({
        "content": [{
            "type": "text",
            "text": serde_json::to_string_pretty(&result).unwrap_or_default()
        }]
    }))
}

fn mcp_to_cmux_method(tool_name: &str) -> Option<&'static str> {
    BROWSER_METHODS
        .iter()
        .find(|m| m.replace('.', "_") == tool_name)
        .copied()
}

fn tools_manifest() -> Vec<Value> {
    BROWSER_METHODS
        .iter()
        .map(|m| {
            let tool = m.replace('.', "_");
            json!({
                "name": tool,
                "description": format!("Forwards to cmux socket method `{m}`. See cmux browser API docs for parameters."),
                "inputSchema": {
                    "type": "object",
                    "additionalProperties": true
                }
            })
        })
        .collect()
}

/// Curated cmux browser.* method list. Each becomes a single MCP tool whose
/// name is the method with `.` replaced by `_` (claude/codex tool names
/// disallow dots).
const BROWSER_METHODS: &[&str] = &[
    "browser.addinitscript",
    "browser.addscript",
    "browser.addstyle",
    "browser.back",
    "browser.check",
    "browser.click",
    "browser.console.clear",
    "browser.console.list",
    "browser.cookies.clear",
    "browser.cookies.get",
    "browser.cookies.set",
    "browser.dblclick",
    "browser.dialog.accept",
    "browser.dialog.dismiss",
    "browser.errors.list",
    "browser.eval",
    "browser.fill",
    "browser.find.alt",
    "browser.find.first",
    "browser.find.label",
    "browser.find.last",
    "browser.find.nth",
    "browser.find.placeholder",
    "browser.find.role",
    "browser.find.testid",
    "browser.find.text",
    "browser.find.title",
    "browser.focus",
    "browser.focus_webview",
    "browser.forward",
    "browser.frame.main",
    "browser.frame.select",
    "browser.geolocation.set",
    "browser.get.attr",
    "browser.get.box",
    "browser.get.count",
    "browser.get.html",
    "browser.get.styles",
    "browser.get.text",
    "browser.get.title",
    "browser.get.value",
    "browser.highlight",
    "browser.hover",
    "browser.input_keyboard",
    "browser.input_mouse",
    "browser.input_touch",
    "browser.is_webview_focused",
    "browser.is.checked",
    "browser.is.enabled",
    "browser.is.visible",
    "browser.keydown",
    "browser.keyup",
    "browser.navigate",
    "browser.network.requests",
    "browser.network.route",
    "browser.network.unroute",
    "browser.offline.set",
    "browser.open_split",
    "browser.press",
    "browser.reload",
    "browser.screenshot",
    "browser.scroll",
    "browser.scroll_into_view",
    "browser.select",
    "browser.snapshot",
    "browser.state.load",
    "browser.state.save",
    "browser.storage.clear",
    "browser.storage.get",
    "browser.storage.set",
    "browser.tab.close",
    "browser.tab.list",
    "browser.tab.new",
    "browser.tab.switch",
    "browser.type",
    "browser.uncheck",
    "browser.url.get",
    "browser.viewport.set",
    "browser.wait",
];

struct SocketBridge {
    stream: UnixStream,
    next_id: AtomicU64,
}

impl SocketBridge {
    fn connect() -> io::Result<Self> {
        let path = resolve_socket_path()?;
        let stream = UnixStream::connect(&path).map_err(|e| {
            io::Error::new(
                e.kind(),
                format!("cannot connect to cmux socket {}: {e}", path.display()),
            )
        })?;
        Ok(Self {
            stream,
            next_id: AtomicU64::new(1),
        })
    }

    fn call(&mut self, method: &'static str, params: Value) -> Result<Value, String> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let req = json!({
            "id": id,
            "method": method,
            "params": params
        });
        let mut line = serde_json::to_string(&req).map_err(|e| format!("encode: {e}"))?;
        line.push('\n');
        self.stream
            .write_all(line.as_bytes())
            .map_err(|e| format!("write: {e}"))?;

        // Read response line by line until we hit a matching id. Notifications
        // (no id) and unrelated responses get dropped silently.
        let mut buf = Vec::with_capacity(4096);
        let mut byte = [0u8; 1];
        loop {
            buf.clear();
            loop {
                let n = self
                    .stream
                    .read(&mut byte)
                    .map_err(|e| format!("read: {e}"))?;
                if n == 0 {
                    return Err("cmux socket closed".to_string());
                }
                if byte[0] == b'\n' {
                    break;
                }
                buf.push(byte[0]);
                if buf.len() > 32 * 1024 * 1024 {
                    return Err("response too large".to_string());
                }
            }
            if buf.is_empty() {
                continue;
            }
            let resp: Value =
                serde_json::from_slice(&buf).map_err(|e| format!("decode: {e}"))?;
            let resp_id = resp.get("id").and_then(|v| v.as_u64());
            if resp_id != Some(id) {
                continue;
            }
            if resp.get("ok").and_then(|v| v.as_bool()) == Some(true) {
                return Ok(resp.get("result").cloned().unwrap_or(Value::Null));
            }
            let err = resp
                .get("error")
                .map(|e| e.to_string())
                .unwrap_or_else(|| "unknown error".into());
            return Err(err);
        }
    }
}

fn resolve_socket_path() -> io::Result<PathBuf> {
    if let Ok(p) = env::var("CMUX_SOCKET_PATH") {
        if !p.is_empty() {
            return Ok(PathBuf::from(p));
        }
    }
    if let Ok(home) = env::var("HOME") {
        let stable = PathBuf::from(home)
            .join("Library/Application Support/cmux/com.cmuxterm.app.sock");
        if stable.exists() {
            return Ok(stable);
        }
    }
    for marker in [
        env::var("HOME")
            .ok()
            .map(|h| PathBuf::from(h).join("Library/Application Support/cmux/last-socket-path")),
        Some(PathBuf::from("/tmp/cmux-last-socket-path")),
    ]
    .into_iter()
    .flatten()
    {
        if let Ok(text) = fs::read_to_string(&marker) {
            let trimmed = text.trim();
            if !trimmed.is_empty() && PathBuf::from(trimmed).exists() {
                return Ok(PathBuf::from(trimmed));
            }
        }
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        "cmux socket not found; set CMUX_SOCKET_PATH",
    ))
}
