//! P5: snapshot test that drives `parse::Session` over canned
//! tmux control-mode wire fixtures and asserts the emitted CPP
//! event sequence. The fixtures in `tests/fixtures/*.tmux` are
//! hand-crafted from the tmux 3.5 control-mode format documented
//! in `tmux(1)`. Real recordings should be appended as they get
//! captured; the assertion shape is the same.

use cmux_tmux::parse::{CppEvent, Session};
use std::path::PathBuf;

fn fixtures_dir() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("tests");
    p.push("fixtures");
    p
}

fn run_fixture(name: &str) -> Vec<CppEvent> {
    let path = fixtures_dir().join(name);
    let raw = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    let mut session = Session::default();
    let mut events = Vec::new();
    for line in raw.lines() {
        events.extend(session.feed(line));
    }
    events
}

#[test]
fn fixture_attach_and_close() {
    let events = run_fixture("01_attach_and_close.tmux");
    assert_eq!(
        events,
        vec![
            CppEvent::LayoutChanged {
                window_id: "@0".into(),
                layout_string: "b3a4,80x24,0,0,1".into(),
            },
            CppEvent::WorkspaceClosed {
                workspace_id: "$0".into(),
            },
        ]
    );
}

#[test]
fn fixture_horizontal_split() {
    let events = run_fixture("02_horizontal_split.tmux");
    assert_eq!(
        events,
        vec![
            CppEvent::LayoutChanged {
                window_id: "@0".into(),
                layout_string: "b3a4,80x24,0,0,1".into(),
            },
            CppEvent::LayoutChanged {
                window_id: "@0".into(),
                layout_string: "c4d5,80x24,0,0{40x24,0,0,1,39x24,41,0,2}".into(),
            },
        ]
    );
}

#[test]
fn fixture_window_close_with_panes() {
    let events = run_fixture("03_window_close_with_panes.tmux");
    let mut exited: Vec<String> = Vec::new();
    let mut layouts: Vec<String> = Vec::new();
    for e in events {
        match e {
            CppEvent::PaneExited { pane_id } => exited.push(pane_id),
            CppEvent::LayoutChanged { layout_string, .. } => layouts.push(layout_string),
            other => panic!("unexpected event: {other:?}"),
        }
    }
    exited.sort();
    assert_eq!(
        layouts,
        vec!["dead,80x24,0,0[80x12,0,0,5,80x11,0,13,6]".to_string()]
    );
    assert_eq!(exited, vec!["%5".to_string(), "%6".to_string()]);
}
