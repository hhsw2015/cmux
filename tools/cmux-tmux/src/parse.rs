/// CPP events emitted by the parser. The shim's I/O layer turns
/// these into `events.subscribe` notifications on the wire.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CppEvent {
    LayoutChanged {
        window_id: String,
        layout_string: String,
    },
}

/// Parse a single line of tmux control-mode output into a CPP
/// event, or `None` if the line is not one we map.
///
/// Lines we currently care about (more arms added as later tests
/// force them):
///   `%layout-change <win-id> <layout-string> [<visible>] [<flags>]`
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
