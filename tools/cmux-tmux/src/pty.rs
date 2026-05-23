//! Byte plumbing for `raw-pty-attach`.
//!
//! Two directions:
//!
//! * Client -> tmux: cmux sends arbitrary bytes; we encode them
//!   as `send-keys -H <hex>...` so binary/UTF-8/ESC all survive
//!   the shell argv boundary.
//! * tmux -> client: tmux's `%output %<pane> <octal-escaped-text>`
//!   events (see [`decode_output_event`]) carry pane bytes; we
//!   un-escape and forward.

use std::fmt;

/// Build a tmux argv that ships `bytes` to `target_pane_id` via
/// `send-keys -H`. Empty input returns an empty argv (caller
/// should skip the spawn rather than send a no-op).
pub fn bytes_to_send_keys_argv(target_pane_id: &str, bytes: &[u8]) -> Vec<String> {
    if bytes.is_empty() {
        return Vec::new();
    }
    let mut argv = Vec::with_capacity(4 + bytes.len());
    argv.push("send-keys".into());
    argv.push("-t".into());
    argv.push(target_pane_id.into());
    argv.push("-H".into());
    for b in bytes {
        argv.push(format!("{b:02x}"));
    }
    argv
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArgvDecodeError {
    pub message: String,
}

impl fmt::Display for ArgvDecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for ArgvDecodeError {}

/// Decode a `%output %<pane> <octal-escaped-text>` line into the
/// pane id and the raw bytes. Returns `None` if the line is not
/// an `%output` event or is malformed.
///
/// tmux escapes any byte that is not printable ASCII (and the
/// literal backslash) as a three-digit octal sequence `\NNN`.
/// Other bytes pass through unchanged.
pub fn decode_output_event(line: &str) -> Option<(String, Vec<u8>)> {
    let line = line.trim_end_matches(['\r', '\n']);
    let rest = line.strip_prefix("%output ")?;
    let (pane, payload) = rest.split_once(' ').unwrap_or((rest, ""));
    let bytes = unescape_octal(payload).ok()?;
    Some((pane.to_string(), bytes))
}

fn unescape_octal(s: &str) -> Result<Vec<u8>, ArgvDecodeError> {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' {
            if i + 3 >= bytes.len() {
                return Err(ArgvDecodeError {
                    message: format!("dangling escape at offset {i}"),
                });
            }
            let triplet = &bytes[i + 1..i + 4];
            if !triplet.iter().all(|b| (b'0'..=b'7').contains(b)) {
                return Err(ArgvDecodeError {
                    message: format!("non-octal escape at offset {i}"),
                });
            }
            let v = ((triplet[0] - b'0') as u32) * 64
                + ((triplet[1] - b'0') as u32) * 8
                + ((triplet[2] - b'0') as u32);
            if v > 0xff {
                return Err(ArgvDecodeError {
                    message: format!("octal value > 0xff at offset {i}: {v}"),
                });
            }
            out.push(v as u8);
            i += 4;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    Ok(out)
}

/// Inverse of [`bytes_to_send_keys_argv`]: parse the hex tail of
/// a `send-keys -H ...` argv back to raw bytes.
pub fn send_keys_argv_to_bytes(argv: &[String]) -> Result<Vec<u8>, ArgvDecodeError> {
    if argv.is_empty() {
        return Ok(Vec::new());
    }
    let h_pos = argv.iter().position(|a| a == "-H").ok_or(ArgvDecodeError {
        message: "argv missing -H flag".into(),
    })?;
    let mut bytes = Vec::with_capacity(argv.len().saturating_sub(h_pos + 1));
    for token in &argv[h_pos + 1..] {
        if token.len() != 2 {
            return Err(ArgvDecodeError {
                message: format!("hex token must be 2 chars, got {token:?}"),
            });
        }
        let b = u8::from_str_radix(token, 16).map_err(|e| ArgvDecodeError {
            message: format!("bad hex token {token:?}: {e}"),
        })?;
        bytes.push(b);
    }
    Ok(bytes)
}
