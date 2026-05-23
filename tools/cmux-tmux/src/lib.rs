// Public surface grows test-by-test. Each `pub mod` line is added the
// moment a failing test in this crate forces it.

pub mod parse;
pub mod translate;

#[cfg(test)]
mod tests {
    // R0: translate a `pane.split` JSON-RPC request into a tmux argv
    // vector. Pure data → data; no I/O.
    //
    //   input  = `{"id":"1","method":"pane.split",
    //              "params":{"target_pane_id":"%3","direction":"right",
    //                        "cwd":"/work"}}`
    //   output = ["split-window", "-h", "-c", "/work", "-t", "%3"]
    //
    // We pin the exact argv shape because tmux is picky about flag
    // ordering with `-c` (must come before `-t` in some versions).
    #[test]
    fn pane_split_right_with_cwd_translates_to_tmux_argv() {
        let request_json = r#"{
            "id": "1",
            "method": "pane.split",
            "params": {
                "target_pane_id": "%3",
                "direction": "right",
                "cwd": "/work"
            }
        }"#;

        let argv = super::translate::request_json_to_tmux_argv(request_json)
            .expect("split request should translate to tmux argv");

        assert_eq!(argv, vec!["split-window", "-h", "-c", "/work", "-t", "%3"]);
    }

    // R1: down direction emits `-v`. tmux uses `-h` for horizontal
    // (split into a right neighbour) and `-v` for vertical (split
    // into a bottom neighbour).
    #[test]
    fn pane_split_down_translates_to_v_flag() {
        let request_json = r#"{
            "id": "2",
            "method": "pane.split",
            "params": {
                "target_pane_id": "%7",
                "direction": "down"
            }
        }"#;

        let argv = super::translate::request_json_to_tmux_argv(request_json)
            .expect("down split should translate");

        assert_eq!(argv, vec!["split-window", "-v", "-t", "%7"]);
    }

    // R2: ping has no tmux equivalent. The shim must answer it
    // locally with `{"result":"pong"}` and never spawn tmux. This
    // forces a `TranslateOutcome` enum so downstream I/O code can
    // distinguish "go run tmux" from "send this response now".
    #[test]
    fn ping_translates_to_no_tmux_call() {
        use super::translate::{translate_request, TranslateOutcome};

        let request_json = r#"{"id":"42","method":"ping","params":{}}"#;

        let outcome = translate_request(request_json).expect("ping translates");

        match outcome {
            TranslateOutcome::ImmediateResponse(resp) => {
                assert_eq!(resp.id, serde_json::json!("42"));
                assert_eq!(resp.result, serde_json::json!("pong"));
            }
            other => panic!("expected ImmediateResponse, got {other:?}"),
        }
    }

    // R3: panes.list -> `tmux list-panes -t <SID> -F <fmt>`. The
    // format string is the parser contract: parse.rs (later) will
    // split each line by `\t`. Pinning the exact format here keeps
    // both sides of the parser/translator boundary in lock-step.
    #[test]
    fn panes_list_translates_to_list_panes() {
        use super::translate::{translate_request, TranslateOutcome};

        let request_json = r#"{
            "id": "3",
            "method": "panes.list",
            "params": { "workspace_id": "$0" }
        }"#;

        let outcome = translate_request(request_json).expect("panes.list translates");
        let argv = match outcome {
            TranslateOutcome::RunTmux(a) => a,
            other => panic!("expected RunTmux, got {other:?}"),
        };

        assert_eq!(
            argv,
            vec![
                "list-panes",
                "-t",
                "$0",
                "-F",
                "#{pane_id}\t#{pane_active}\t#{pane_width}\t#{pane_height}",
            ]
        );
    }

    // R4: workspace.list -> `tmux list-sessions -F <fmt>`. No
    // params; format covers id, name and attach state.
    #[test]
    fn workspace_list_translates_to_list_sessions() {
        use super::translate::{translate_request, TranslateOutcome};

        let request_json = r#"{"id":"4","method":"workspace.list","params":{}}"#;

        let argv = match translate_request(request_json).expect("workspace.list translates") {
            TranslateOutcome::RunTmux(a) => a,
            other => panic!("expected RunTmux, got {other:?}"),
        };

        assert_eq!(
            argv,
            vec![
                "list-sessions",
                "-F",
                "#{session_id}\t#{session_name}\t#{session_attached}",
            ]
        );
    }

    // R5: pane.resize emits absolute -x/-y. tmux is integer-cell;
    // any rational ratio comes pre-quantized from the caller. The
    // shim never tries to interpret fractional sizes here.
    #[test]
    fn pane_resize_translates_to_resize_pane() {
        use super::translate::{translate_request, TranslateOutcome};

        let request_json = r#"{
            "id": "5",
            "method": "pane.resize",
            "params": { "target_pane_id": "%9", "cols": 80, "rows": 24 }
        }"#;

        let argv = match translate_request(request_json).expect("pane.resize translates") {
            TranslateOutcome::RunTmux(a) => a,
            other => panic!("expected RunTmux, got {other:?}"),
        };

        assert_eq!(
            argv,
            vec!["resize-pane", "-t", "%9", "-x", "80", "-y", "24"]
        );
    }

    // R6: pane.focus -> select-pane -t TID. Trivial.
    #[test]
    fn pane_focus_translates_to_select_pane() {
        use super::translate::{translate_request, TranslateOutcome};

        let request_json = r#"{"id":"6","method":"pane.focus","params":{"target_pane_id":"%4"}}"#;
        let argv = match translate_request(request_json).expect("pane.focus translates") {
            TranslateOutcome::RunTmux(a) => a,
            other => panic!("expected RunTmux, got {other:?}"),
        };
        assert_eq!(argv, vec!["select-pane", "-t", "%4"]);
    }

    // R7: pane.close -> kill-pane -t TID. Trivial.
    #[test]
    fn pane_close_translates_to_kill_pane() {
        use super::translate::{translate_request, TranslateOutcome};

        let request_json = r#"{"id":"7","method":"pane.close","params":{"target_pane_id":"%5"}}"#;
        let argv = match translate_request(request_json).expect("pane.close translates") {
            TranslateOutcome::RunTmux(a) => a,
            other => panic!("expected RunTmux, got {other:?}"),
        };
        assert_eq!(argv, vec!["kill-pane", "-t", "%5"]);
    }

    // R8: pane.set_split_ratio is the first request that needs
    // workspace context. cmux side speaks ratios (0.0..=1.0); tmux
    // wants integer cells. The shim quantizes using the parent
    // split's known length on its split axis. The mapping from
    // pane-id to (axis, total_cells) is supplied in a snapshot
    // by the caller — translate is still pure.
    #[test]
    fn set_split_ratio_translates_with_ratio_to_cells_conversion() {
        use super::translate::{translate_request_in_context, TranslateContext, TranslateOutcome};

        let mut ctx = TranslateContext::default();
        ctx.split_geometry.insert("%2".into(), ('h', 100));

        let request_json = r#"{
            "id": "8",
            "method": "pane.set_split_ratio",
            "params": { "target_pane_id": "%2", "ratio": 0.6 }
        }"#;

        let argv = match translate_request_in_context(request_json, &ctx)
            .expect("set_split_ratio translates")
        {
            TranslateOutcome::RunTmux(a) => a,
            other => panic!("expected RunTmux, got {other:?}"),
        };

        assert_eq!(argv, vec!["resize-pane", "-t", "%2", "-x", "60"]);
    }

    // R8b: vertical split uses -y instead of -x.
    #[test]
    fn set_split_ratio_vertical_uses_y_flag() {
        use super::translate::{translate_request_in_context, TranslateContext, TranslateOutcome};

        let mut ctx = TranslateContext::default();
        ctx.split_geometry.insert("%6".into(), ('v', 50));

        let request_json = r#"{
            "id": "9",
            "method": "pane.set_split_ratio",
            "params": { "target_pane_id": "%6", "ratio": 0.5 }
        }"#;

        let argv = match translate_request_in_context(request_json, &ctx).unwrap() {
            TranslateOutcome::RunTmux(a) => a,
            other => panic!("expected RunTmux, got {other:?}"),
        };

        assert_eq!(argv, vec!["resize-pane", "-t", "%6", "-y", "25"]);
    }

    // R9: unknown method must round-trip back to the client as a
    // JSON-RPC error envelope (code -32601), not as a Rust error.
    // The bin's I/O layer cannot do anything useful with a Rust
    // panic; it needs a serializable response to put on the wire.
    #[test]
    fn unknown_method_returns_method_not_found() {
        use super::translate::{translate_request, TranslateOutcome, METHOD_NOT_FOUND};

        let request_json = r#"{"id":"99","method":"frobnicate","params":{}}"#;

        let outcome = translate_request(request_json).expect("unknown method translates");

        match outcome {
            TranslateOutcome::ImmediateError(err) => {
                assert_eq!(err.id, serde_json::json!("99"));
                assert_eq!(err.error.code, METHOD_NOT_FOUND);
                assert!(
                    err.error.message.contains("frobnicate"),
                    "message should mention the bad method, got {:?}",
                    err.error.message
                );
            }
            other => panic!("expected ImmediateError, got {other:?}"),
        }
    }

    // P0: tmux control mode emits `%layout-change <win> <layout>
    // [<visible>] [<flags>]`. The shim translates that to a CPP
    // `layout_changed` event keyed on the tmux window id and
    // carrying the raw layout string. Layout-string parsing is
    // P3; for now we just round-trip the string verbatim.
    #[test]
    fn parse_layout_change_event_emits_cpp_layout_changed() {
        use super::parse::{tmux_line, CppEvent};

        let event = tmux_line("%layout-change @0 6c93,80x24,0,0,1").expect("layout-change parses");

        match event {
            CppEvent::LayoutChanged {
                window_id,
                layout_string,
            } => {
                assert_eq!(window_id, "@0");
                assert_eq!(layout_string, "6c93,80x24,0,0,1");
            }
            other => panic!("expected LayoutChanged, got {other:?}"),
        }
    }

    // P0b: extra trailing fields (visible-layout, flags) are
    // tolerated. tmux >=3.2 adds them; we parse the first two
    // tokens after the verb and ignore the rest.
    #[test]
    fn parse_layout_change_with_trailing_tokens_still_extracts_first_two() {
        use super::parse::{tmux_line, CppEvent};

        let event = tmux_line("%layout-change @1 abcd,80x24,0,0{40x24,0,0,1,40x24,40,0,2} * @1")
            .expect("layout-change with trailing parses");

        match event {
            CppEvent::LayoutChanged {
                window_id,
                layout_string,
            } => {
                assert_eq!(window_id, "@1");
                assert_eq!(layout_string, "abcd,80x24,0,0{40x24,0,0,1,40x24,40,0,2}");
            }
            other => panic!("expected LayoutChanged, got {other:?}"),
        }
    }

    // P1: tmux's `%window-close <win>` doesn't enumerate the panes
    // that died with the window — the shim has to remember pane->
    // window ownership. So parsing grows a stateful accumulator
    // (`parse::Session`). After a window closes, the accumulator
    // emits one `PaneExited` per pane that lived in it.
    #[test]
    fn parse_window_close_emits_pane_exited_for_each_owned_pane() {
        use super::parse::{CppEvent, Session};

        let mut session = Session::default();
        session.record_pane("@5", "%10");
        session.record_pane("@5", "%11");
        // a pane in another window should NOT show up in @5's close.
        session.record_pane("@6", "%99");

        let events = session.feed("%window-close @5");

        let mut exited: Vec<String> = events
            .into_iter()
            .map(|e| match e {
                CppEvent::PaneExited { pane_id } => pane_id,
                other => panic!("expected PaneExited, got {other:?}"),
            })
            .collect();
        exited.sort();
        assert_eq!(exited, vec!["%10".to_string(), "%11".to_string()]);

        // The window's pane set is gone after the close; a second
        // close for the same window emits nothing.
        assert!(session.feed("%window-close @5").is_empty());
    }

    // P2: when tmux's last attached session goes away, control
    // mode emits `%session-changed` with an empty session id (or
    // a different id, but the previous one is gone). The shim
    // turns that into a `WorkspaceClosed` event keyed on the
    // session id we last knew was active.
    #[test]
    fn parse_session_changed_to_empty_emits_workspace_closed() {
        use super::parse::{CppEvent, Session};

        let mut session = Session::default();
        // Initial attach: tells the accumulator which session is
        // current. No event fires.
        let attach_events = session.feed("%session-changed $5 work");
        assert!(attach_events.is_empty(), "{attach_events:?}");

        // Subsequent change to empty fires WorkspaceClosed for $5.
        let close_events = session.feed("%session-changed  ");
        assert_eq!(
            close_events,
            vec![CppEvent::WorkspaceClosed {
                workspace_id: "$5".into()
            }]
        );

        // After the close, no current session — re-emit guards.
        assert!(session.feed("%session-changed  ").is_empty());
    }
}

#[cfg(test)]
mod proptests {
    use super::translate::{translate_request, translate_request_in_context, TranslateContext};
    use proptest::prelude::*;

    // R10: translate_request must be panic-free for any input.
    // Garbage strings, partial JSON, exotic numbers — all should
    // round-trip to a structured Result (Ok variant or Err), never
    // a panic / overflow / unwrap. This is a fuzz-style guard so a
    // malicious / corrupt client cannot crash the shim.
    proptest! {
        #[test]
        fn arbitrary_strings_never_panic(s in "\\PC{0,256}") {
            let _ = translate_request(&s);
        }

        #[test]
        fn arbitrary_request_shapes_never_panic(
            method in "[a-zA-Z._-]{0,32}",
            target in "%[0-9]{1,4}",
            ratio in -10.0f64..10.0,
            cols in 0u64..10_000,
            rows in 0u64..10_000,
        ) {
            let json = serde_json::json!({
                "id": "x",
                "method": method,
                "params": {
                    "target_pane_id": target,
                    "direction": "right",
                    "cwd": "/tmp",
                    "ratio": ratio,
                    "cols": cols,
                    "rows": rows,
                    "workspace_id": "$0",
                }
            });
            let mut ctx = TranslateContext::default();
            ctx.split_geometry.insert(target.clone(), ('h', 100));
            let _ = translate_request_in_context(&json.to_string(), &ctx);
        }
    }
}
