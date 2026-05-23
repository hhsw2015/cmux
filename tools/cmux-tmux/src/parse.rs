use std::collections::{BTreeSet, HashMap};

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
