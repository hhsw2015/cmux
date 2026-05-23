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
}
