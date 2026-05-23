// Public surface grows test-by-test. Each `pub mod` line is added the
// moment a failing test in this crate forces it.

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
}
