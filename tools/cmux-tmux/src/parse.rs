use std::collections::{BTreeSet, HashMap};
use std::fmt;

/// CPP events emitted by the parser. The shim's I/O layer turns
/// these into `events.subscribe` notifications on the wire.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CppEvent {
    LayoutChanged {
        window_id: String,
        layout_string: String,
    },
    PaneExited {
        pane_id: String,
    },
    WorkspaceClosed {
        workspace_id: String,
    },
}

/// Pane / split rectangle in tmux cells.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Geometry {
    pub w: u32,
    pub h: u32,
    pub x: u32,
    pub y: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Orientation {
    /// `{...}` in tmux's layout grammar — children placed side by
    /// side along X.
    LeftRight,
    /// `[...]` in tmux's layout grammar — children stacked along
    /// Y.
    TopBottom,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LayoutNode {
    Leaf {
        geometry: Geometry,
        pane_id: String,
    },
    Split {
        geometry: Geometry,
        orientation: Orientation,
        children: Vec<LayoutNode>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LayoutParseError {
    pub message: String,
    pub offset: usize,
}

impl fmt::Display for LayoutParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} at offset {}", self.message, self.offset)
    }
}

impl std::error::Error for LayoutParseError {}

/// Parse a tmux layout string. Format:
///
/// ```text
/// <checksum>,WxH,X,Y[,<paneN> | { children } | [ children ] ]
/// ```
///
/// `{}` = LeftRight (panes side-by-side), `[]` = TopBottom
/// (panes stacked). Pane numbers come back as `%N` to match the
/// cmux pane id form.
pub fn parse_layout(s: &str) -> Result<LayoutNode, LayoutParseError> {
    let body = match s.find(',') {
        Some(i) => &s[i + 1..],
        None => {
            return Err(LayoutParseError {
                message: "missing checksum separator".into(),
                offset: 0,
            })
        }
    };
    let mut cursor = Cursor::new(body, s.len() - body.len());
    let node = parse_node(&mut cursor)?;
    if !cursor.eof() {
        return Err(LayoutParseError {
            message: format!("trailing garbage: {:?}", cursor.rest()),
            offset: cursor.absolute(),
        });
    }
    Ok(node)
}

struct Cursor<'a> {
    s: &'a str,
    pos: usize,
    base: usize,
}

impl<'a> Cursor<'a> {
    fn new(s: &'a str, base: usize) -> Self {
        Self { s, pos: 0, base }
    }
    fn eof(&self) -> bool {
        self.pos >= self.s.len()
    }
    fn peek(&self) -> Option<char> {
        self.s[self.pos..].chars().next()
    }
    fn advance(&mut self, n: usize) {
        self.pos += n;
    }
    fn rest(&self) -> &str {
        &self.s[self.pos..]
    }
    fn absolute(&self) -> usize {
        self.base + self.pos
    }
}

fn parse_node(c: &mut Cursor<'_>) -> Result<LayoutNode, LayoutParseError> {
    let geometry = parse_geometry(c)?;
    match c.peek() {
        Some('{') => parse_split(c, geometry, Orientation::LeftRight, '{', '}'),
        Some('[') => parse_split(c, geometry, Orientation::TopBottom, '[', ']'),
        Some(',') => {
            c.advance(1);
            let pane_num = take_while_digits(c)?;
            Ok(LayoutNode::Leaf {
                geometry,
                pane_id: format!("%{pane_num}"),
            })
        }
        _ => Err(LayoutParseError {
            message: format!(
                "expected '{{', '[', or ',' after geometry, got {:?}",
                c.rest()
            ),
            offset: c.absolute(),
        }),
    }
}

fn parse_split(
    c: &mut Cursor<'_>,
    geometry: Geometry,
    orientation: Orientation,
    open: char,
    close: char,
) -> Result<LayoutNode, LayoutParseError> {
    debug_assert_eq!(c.peek(), Some(open));
    c.advance(open.len_utf8());
    let mut children = Vec::new();
    loop {
        children.push(parse_node(c)?);
        match c.peek() {
            Some(',') => {
                c.advance(1);
            }
            Some(ch) if ch == close => {
                c.advance(close.len_utf8());
                break;
            }
            other => {
                return Err(LayoutParseError {
                    message: format!("expected ',' or '{close}' in split, got {other:?}"),
                    offset: c.absolute(),
                });
            }
        }
    }
    Ok(LayoutNode::Split {
        geometry,
        orientation,
        children,
    })
}

fn parse_geometry(c: &mut Cursor<'_>) -> Result<Geometry, LayoutParseError> {
    let w = take_while_digits(c)?;
    expect_char(c, 'x')?;
    let h = take_while_digits(c)?;
    expect_char(c, ',')?;
    let x = take_while_digits(c)?;
    expect_char(c, ',')?;
    let y = take_while_digits(c)?;
    Ok(Geometry { w, h, x, y })
}

fn expect_char(c: &mut Cursor<'_>, want: char) -> Result<(), LayoutParseError> {
    match c.peek() {
        Some(ch) if ch == want => {
            c.advance(want.len_utf8());
            Ok(())
        }
        other => Err(LayoutParseError {
            message: format!("expected {want:?}, got {other:?}"),
            offset: c.absolute(),
        }),
    }
}

fn take_while_digits(c: &mut Cursor<'_>) -> Result<u32, LayoutParseError> {
    let start = c.pos;
    while let Some(ch) = c.peek() {
        if ch.is_ascii_digit() {
            c.advance(1);
        } else {
            break;
        }
    }
    if c.pos == start {
        return Err(LayoutParseError {
            message: "expected digits".into(),
            offset: c.absolute(),
        });
    }
    c.s[start..c.pos]
        .parse::<u32>()
        .map_err(|e| LayoutParseError {
            message: format!("bad number: {e}"),
            offset: c.base + start,
        })
}

/// Render a [`LayoutNode`] back into the body of a tmux layout
/// string (i.e. without the leading 4-hex-digit checksum). The
/// inverse of [`parse_layout`] modulo the checksum prefix; tests
/// add `"0000,"` to round-trip through the parser.
pub fn render_layout_body(node: &LayoutNode) -> String {
    let mut out = String::new();
    render_into(node, &mut out);
    out
}

/// Convenience wrapper that emits a fixed-zero checksum prefix
/// so the output is directly parseable by [`parse_layout`].
pub fn render_layout(node: &LayoutNode) -> String {
    format!("0000,{}", render_layout_body(node))
}

fn render_into(node: &LayoutNode, out: &mut String) {
    use std::fmt::Write;
    match node {
        LayoutNode::Leaf { geometry, pane_id } => {
            let n = pane_id.strip_prefix('%').unwrap_or(pane_id);
            let _ = write!(
                out,
                "{}x{},{},{},{}",
                geometry.w, geometry.h, geometry.x, geometry.y, n
            );
        }
        LayoutNode::Split {
            geometry,
            orientation,
            children,
        } => {
            let (open, close) = match orientation {
                Orientation::LeftRight => ('{', '}'),
                Orientation::TopBottom => ('[', ']'),
            };
            let _ = write!(
                out,
                "{}x{},{},{}{}",
                geometry.w, geometry.h, geometry.x, geometry.y, open
            );
            for (i, child) in children.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                render_into(child, out);
            }
            out.push(close);
        }
    }
}

/// Stateless single-line parser for events that don't need
/// session context (currently only `%layout-change`). Stateful
/// events go through [`Session::feed`].
pub fn tmux_line(line: &str) -> Option<CppEvent> {
    let line = line.trim_end_matches(['\r', '\n']);
    let mut tokens = line.split(' ');
    let verb = tokens.next()?;
    match verb {
        "%layout-change" => {
            let window_id = tokens.next()?.to_string();
            let layout_string = tokens.next()?.to_string();
            Some(CppEvent::LayoutChanged {
                window_id,
                layout_string,
            })
        }
        _ => None,
    }
}

/// Accumulator for tmux events that the wire does not carry
/// enough context for. tmux fires `%window-close <win>` without
/// listing the panes that died, so the shim must remember
/// ownership and synthesize one `PaneExited` per pane.
#[derive(Debug, Default, Clone)]
pub struct Session {
    panes_by_window: HashMap<String, BTreeSet<String>>,
    current_session: Option<String>,
}

impl Session {
    /// Record that `pane_id` lives in `window_id`. Idempotent.
    pub fn record_pane(&mut self, window_id: &str, pane_id: &str) {
        self.panes_by_window
            .entry(window_id.to_string())
            .or_default()
            .insert(pane_id.to_string());
    }

    /// Feed a single tmux control-mode line and return any CPP
    /// events it produces. May be zero, one, or many.
    pub fn feed(&mut self, line: &str) -> Vec<CppEvent> {
        let line = line.trim_end_matches(['\r', '\n']);
        let mut tokens = line.split(' ');
        let Some(verb) = tokens.next() else {
            return Vec::new();
        };
        match verb {
            "%window-close" => {
                let Some(window_id) = tokens.next() else {
                    return Vec::new();
                };
                let Some(panes) = self.panes_by_window.remove(window_id) else {
                    return Vec::new();
                };
                panes
                    .into_iter()
                    .map(|pane_id| CppEvent::PaneExited { pane_id })
                    .collect()
            }
            "%session-changed" => {
                let new_id = tokens.next().unwrap_or("");
                if new_id.is_empty() {
                    if let Some(prev) = self.current_session.take() {
                        return vec![CppEvent::WorkspaceClosed { workspace_id: prev }];
                    }
                    return Vec::new();
                }
                self.current_session = Some(new_id.to_string());
                Vec::new()
            }
            _ => match tmux_line(line) {
                Some(ev) => vec![ev],
                None => Vec::new(),
            },
        }
    }
}
