// Public surface grows test-by-test. Each `pub mod` line is added the
// moment a failing test in this crate forces it.

pub mod bsp;
pub mod parse;
pub mod pty;
pub mod tmux_response;
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
                // Match cmux's HerdrApiClient.ping() which reads
                // result["version"] (String) and result["protocol"]
                // (Int). The shape — not the values — is the
                // contract; version comes from CARGO_PKG_VERSION.
                assert_eq!(resp.result["protocol"], serde_json::json!(1));
                assert!(resp.result["version"].is_string());
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

    // I2a: event_to_json shapes parsed CppEvents into JSON
    // notifications. Notifications have no `id` field so the
    // client can distinguish them from RPC responses.
    #[test]
    fn event_to_json_shapes_layout_changed() {
        use super::parse::CppEvent;
        use super::tmux_response::event_to_json;

        let v = event_to_json(
            &CppEvent::LayoutChanged {
                window_id: "@0".into(),
                layout_string: "abcd,80x24,0,0,1".into(),
            },
            "$3",
        );
        // layout.changed payload follows herdr's
        // HerdrLayoutChangedPayload: data.tree = HerdrLayoutTree.
        assert_eq!(v["event"], serde_json::json!("layout.changed"));
        let tree = &v["data"]["tree"];
        assert_eq!(tree["workspace_id"], serde_json::json!("$3"));
        assert_eq!(tree["tab_id"], serde_json::json!("@0"));
        assert_eq!(tree["root"]["kind"], serde_json::json!("pane"));
        assert_eq!(tree["root"]["pane_id"], serde_json::json!("%1"));
        assert!(v.get("id").is_none());
    }

    #[test]
    fn event_to_json_shapes_pane_exited_and_workspace_closed() {
        use super::parse::CppEvent;
        use super::tmux_response::event_to_json;

        assert_eq!(
            event_to_json(
                &CppEvent::PaneExited {
                    pane_id: "%4".into()
                },
                "$5"
            ),
            serde_json::json!({
                "event": "pane.exited",
                "data": {"pane_id": "%4", "workspace_id": "$5"}
            })
        );
        assert_eq!(
            event_to_json(
                &CppEvent::WorkspaceClosed {
                    workspace_id: "$5".into()
                },
                "$5"
            ),
            serde_json::json!({"event": "workspace.closed", "data": {"workspace_id": "$5"}})
        );
    }

    // I1b: tmux capture-args helper. The bin appends these to the
    // base argv from translate so commands that "create" a thing
    // (workspace.create, pane.split) can return its id.
    #[test]
    fn capture_args_for_create_methods() {
        use super::tmux_response::capture_args_for;
        assert_eq!(
            capture_args_for("workspace.create"),
            Some(vec!["-P".to_string(), "-F".into(), "#{session_id}".into()])
        );
        assert_eq!(
            capture_args_for("pane.split"),
            Some(vec!["-P".to_string(), "-F".into(), "#{pane_id}".into()])
        );
        assert_eq!(capture_args_for("panes.list"), None);
        assert_eq!(capture_args_for("pane.focus"), None);
    }

    // I1c: shape_response turns raw tmux stdout into the CPP
    // result envelope. Each method has its own shaper.
    #[test]
    fn shape_workspace_create_response() {
        use super::tmux_response::shape_response;

        let resp =
            shape_response("workspace.create", serde_json::json!("10"), "$3\n").expect("shape ok");

        assert_eq!(resp.id, serde_json::json!("10"));
        assert_eq!(resp.result, serde_json::json!({"workspace_id": "$3"}));
    }

    #[test]
    fn shape_pane_split_response() {
        use super::tmux_response::shape_response;

        let resp = shape_response("pane.split", serde_json::json!("11"), "%7").expect("shape ok");

        assert_eq!(resp.result, serde_json::json!({"pane_id": "%7"}));
    }

    #[test]
    fn shape_panes_list_response_parses_tab_separated_lines() {
        use super::tmux_response::shape_response;

        let stdout = "%1\t1\t80\t24\n%2\t0\t40\t24\n";
        let resp = shape_response("panes.list", serde_json::json!("12"), stdout).expect("shape ok");

        assert_eq!(
            resp.result,
            serde_json::json!({
                "panes": [
                    {"pane_id": "%1", "active": true, "cols": 80, "rows": 24},
                    {"pane_id": "%2", "active": false, "cols": 40, "rows": 24},
                ]
            })
        );
    }

    #[test]
    fn shape_workspace_list_response_parses_session_lines() {
        use super::tmux_response::shape_response;

        let stdout = "$0\twork\t1\n$5\tidle\t0\n";
        let resp =
            shape_response("workspace.list", serde_json::json!("13"), stdout).expect("shape ok");

        assert_eq!(
            resp.result,
            serde_json::json!({
                "workspaces": [
                    {"workspace_id": "$0", "name": "work", "attached": true},
                    {"workspace_id": "$5", "name": "idle", "attached": false},
                ]
            })
        );
    }

    // For methods with no useful output, shape_response returns
    // {result: {}} — cmux drops non-dict results silently, so an
    // empty object is the void-return shape.
    #[test]
    fn shape_pane_focus_response_is_empty_object() {
        use super::tmux_response::shape_response;

        let resp = shape_response("pane.focus", serde_json::json!("14"), "").expect("shape ok");
        assert_eq!(resp.result, serde_json::json!({}));
    }

    // L1a: a single-pane tmux layout converts to a Pane leaf.
    // The herdr wire shape is `{kind: "pane", pane_id}`.
    #[test]
    fn bsp_converter_leaf() {
        use super::bsp::{tmux_to_bsp, BspNode};
        use super::parse::parse_layout;

        let tree = parse_layout("1234,80x24,0,0,1").unwrap();
        let bsp = tmux_to_bsp(&tree);
        match bsp {
            BspNode::Pane { pane_id } => assert_eq!(pane_id, "%1"),
            other => panic!("expected Pane, got {other:?}"),
        }
    }

    // L1b: tmux's `{}` (LeftRight, side-by-side) becomes herdr's
    // `horizontal` direction. ratio = first.width / total_width.
    #[test]
    fn bsp_converter_h_split_two_children() {
        use super::bsp::{tmux_to_bsp, BspNode, BspSplitDirection};
        use super::parse::parse_layout;

        // 80x24 split into 40 / 39 — divider is at 40, so first
        // gets 40 cells; total along x = 40 + 39 = 79 (the
        // divider takes 1 cell so it's not 80).
        let tree = parse_layout("abcd,80x24,0,0{40x24,0,0,1,39x24,41,0,2}").unwrap();
        let bsp = tmux_to_bsp(&tree);
        match bsp {
            BspNode::Split {
                direction,
                ratio,
                first,
                second,
            } => {
                assert_eq!(direction, BspSplitDirection::Horizontal);
                let expected = 40.0 / 79.0;
                assert!(
                    (ratio - expected).abs() < 1e-4,
                    "ratio {ratio} not near {expected}"
                );
                match (*first, *second) {
                    (BspNode::Pane { pane_id: p1 }, BspNode::Pane { pane_id: p2 }) => {
                        assert_eq!(p1, "%1");
                        assert_eq!(p2, "%2");
                    }
                    other => panic!("expected two pane leaves, got {other:?}"),
                }
            }
            other => panic!("expected Split, got {other:?}"),
        }
    }

    // L1c: tmux's `[]` (TopBottom, stacked) becomes herdr
    // `vertical`. Ratio uses heights along y.
    #[test]
    fn bsp_converter_v_split_two_children() {
        use super::bsp::{tmux_to_bsp, BspNode, BspSplitDirection};
        use super::parse::parse_layout;

        // 80x24 stacked into 12/11.
        let tree = parse_layout("ef01,80x24,0,0[80x12,0,0,1,80x11,0,13,2]").unwrap();
        let bsp = tmux_to_bsp(&tree);
        match bsp {
            BspNode::Split {
                direction, ratio, ..
            } => {
                assert_eq!(direction, BspSplitDirection::Vertical);
                let expected = 12.0 / 23.0;
                assert!((ratio - expected).abs() < 1e-4);
            }
            other => panic!("expected Split, got {other:?}"),
        }
    }

    // L1d: a 3-child tmux split becomes a right-leaning binary
    // chain. tmux `{a,b,c}` → split(a, split(b, c)) where the
    // outer ratio is a.size / total and the inner ratio is
    // b.size / (b.size + c.size).
    #[test]
    fn bsp_converter_h_split_three_children_right_leaning() {
        use super::bsp::{tmux_to_bsp, BspNode, BspSplitDirection};
        use super::parse::parse_layout;

        // 80 wide, three columns: 26 / 27 / 26 (with two
        // divider cells eaten between them; sums to 79 along x).
        let tree = parse_layout("1111,80x24,0,0{26x24,0,0,1,26x24,27,0,2,26x24,54,0,3}").unwrap();
        let bsp = tmux_to_bsp(&tree);
        let (first, second) = match bsp {
            BspNode::Split {
                direction,
                ratio,
                first,
                second,
            } => {
                assert_eq!(direction, BspSplitDirection::Horizontal);
                // outer ratio = 26 / (26 + 26 + 26) = 1/3
                assert!((ratio - 1.0 / 3.0).abs() < 1e-3);
                (*first, *second)
            }
            other => panic!("expected outer Split, got {other:?}"),
        };
        match first {
            BspNode::Pane { pane_id } => assert_eq!(pane_id, "%1"),
            other => panic!("expected outer first to be Pane, got {other:?}"),
        }
        match second {
            BspNode::Split {
                direction,
                ratio,
                first,
                second,
            } => {
                assert_eq!(direction, BspSplitDirection::Horizontal);
                // inner ratio = 26 / (26 + 26) = 1/2
                assert!((ratio - 0.5).abs() < 1e-3);
                match (*first, *second) {
                    (BspNode::Pane { pane_id: p2 }, BspNode::Pane { pane_id: p3 }) => {
                        assert_eq!(p2, "%2");
                        assert_eq!(p3, "%3");
                    }
                    other => panic!("inner children: {other:?}"),
                }
            }
            other => panic!("expected inner Split, got {other:?}"),
        }
    }

    // L1e: nested splits round-trip directions correctly.
    #[test]
    fn bsp_converter_nested_mixed_orientations() {
        use super::bsp::{tmux_to_bsp, BspNode, BspSplitDirection};
        use super::parse::parse_layout;

        // 80x24 split horizontally into a 40-wide column and a
        // 39-wide column; the right column itself is split top/
        // bottom into 40x12 / 40x11.
        let tree =
            parse_layout("2222,80x24,0,0{40x24,0,0,1,39x24,41,0[39x12,41,0,2,39x11,41,13,3]}")
                .unwrap();
        let bsp = tmux_to_bsp(&tree);
        let second = match bsp {
            BspNode::Split {
                direction, second, ..
            } => {
                assert_eq!(direction, BspSplitDirection::Horizontal);
                *second
            }
            other => panic!("outer: {other:?}"),
        };
        match second {
            BspNode::Split { direction, .. } => {
                assert_eq!(direction, BspSplitDirection::Vertical);
            }
            other => panic!("inner expected Vertical Split, got {other:?}"),
        }
    }

    // W2a: workspace.close kills the tmux session.
    #[test]
    fn workspace_close_translates_to_kill_session() {
        use super::translate::{translate_request, TranslateOutcome};

        let request_json =
            r#"{"id":"30","method":"workspace.close","params":{"workspace_id":"$2"}}"#;
        let argv = match translate_request(request_json).expect("close translates") {
            TranslateOutcome::RunTmux(a) => a,
            other => panic!("expected RunTmux, got {other:?}"),
        };
        assert_eq!(argv, vec!["kill-session", "-t", "$2"]);
    }

    // W2b: workspace.rename targets the session and supplies a
    // new name.
    #[test]
    fn workspace_rename_translates_to_rename_session() {
        use super::translate::{translate_request, TranslateOutcome};

        let request_json = r#"{
            "id": "31",
            "method": "workspace.rename",
            "params": { "workspace_id": "$4", "name": "renamed" }
        }"#;
        let argv = match translate_request(request_json).expect("rename translates") {
            TranslateOutcome::RunTmux(a) => a,
            other => panic!("expected RunTmux, got {other:?}"),
        };
        assert_eq!(argv, vec!["rename-session", "-t", "$4", "renamed"]);
    }

    // W1a: workspace.attach reuses list-panes — tmux has no
    // separate "attach" notion at the data-shape level. The
    // shim wraps the panes array with workspace_id so the
    // client can use a single response envelope on first open.
    #[test]
    fn workspace_attach_translates_to_list_panes() {
        use super::translate::{translate_request, TranslateOutcome};

        let request_json = r#"{
            "id": "20",
            "method": "workspace.attach",
            "params": { "workspace_id": "$3" }
        }"#;

        let argv = match translate_request(request_json).expect("attach translates") {
            TranslateOutcome::RunTmux(a) => a,
            other => panic!("expected RunTmux, got {other:?}"),
        };
        assert_eq!(
            argv,
            vec![
                "list-panes",
                "-t",
                "$3",
                "-F",
                "#{pane_id}\t#{pane_active}\t#{pane_width}\t#{pane_height}",
            ]
        );
    }

    // W1b: shape_response_with_params for workspace.attach
    // wraps panes inside {workspace_id, panes}. The id comes
    // from the request params, not tmux stdout.
    #[test]
    fn shape_workspace_attach_response_wraps_panes() {
        use super::tmux_response::shape_response_with_params;

        let stdout = "%1\t1\t80\t24\n%2\t0\t40\t24\n";
        let params = serde_json::json!({"workspace_id": "$3"});
        let resp = shape_response_with_params(
            "workspace.attach",
            serde_json::json!("20"),
            stdout,
            &params,
        )
        .expect("shape ok");

        assert_eq!(
            resp.result,
            serde_json::json!({
                "workspace_id": "$3",
                "panes": [
                    {"pane_id": "%1", "active": true, "cols": 80, "rows": 24},
                    {"pane_id": "%2", "active": false, "cols": 40, "rows": 24},
                ]
            })
        );
    }

    // I1a: workspace.create -> new-session -d [-s NAME] [-c CWD].
    // -d keeps the new session detached so we don't need a tty.
    // The bin appends `-P -F '#{session_id}'` at exec time so the
    // shim can answer with the freshly-created workspace id.
    #[test]
    fn workspace_create_translates_to_new_session() {
        use super::translate::{translate_request, TranslateOutcome};

        let request_json = r#"{
            "id": "10",
            "method": "workspace.create",
            "params": { "name": "work", "cwd": "/home/u" }
        }"#;

        let argv = match translate_request(request_json).expect("workspace.create translates") {
            TranslateOutcome::RunTmux(a) => a,
            other => panic!("expected RunTmux, got {other:?}"),
        };

        assert_eq!(
            argv,
            vec!["new-session", "-d", "-s", "work", "-c", "/home/u"]
        );

        // Without name and cwd: just `new-session -d`.
        let bare_json = r#"{"id":"11","method":"workspace.create","params":{}}"#;
        let bare_argv = match translate_request(bare_json).expect("bare create translates") {
            TranslateOutcome::RunTmux(a) => a,
            other => panic!("expected RunTmux, got {other:?}"),
        };
        assert_eq!(bare_argv, vec!["new-session", "-d"]);
    }

    // L4a: pane.swap maps to tmux swap-pane -s A -t B.
    #[test]
    fn pane_swap_translates_to_swap_pane() {
        use super::translate::{translate_request, TranslateOutcome};

        let request_json = r#"{
            "id": "20",
            "method": "pane.swap",
            "params": { "a_pane_id": "%2", "b_pane_id": "%5" }
        }"#;
        let argv = match translate_request(request_json).expect("swap translates") {
            TranslateOutcome::RunTmux(a) => a,
            other => panic!("expected RunTmux, got {other:?}"),
        };
        assert_eq!(argv, vec!["swap-pane", "-s", "%2", "-t", "%5"]);
    }

    // L4b: tab.list maps to list-windows with our pinned format.
    #[test]
    fn tab_list_translates_to_list_windows() {
        use super::translate::{translate_request, TranslateOutcome};

        let request_json = r#"{
            "id": "21",
            "method": "tab.list",
            "params": { "workspace_id": "$0" }
        }"#;
        let argv = match translate_request(request_json).expect("tab.list translates") {
            TranslateOutcome::RunTmux(a) => a,
            other => panic!("expected RunTmux, got {other:?}"),
        };
        assert_eq!(
            argv,
            vec![
                "list-windows",
                "-t",
                "$0",
                "-F",
                "#{window_id}\t#{window_index}\t#{window_name}\t#{window_active}",
            ]
        );
    }

    // L4c: tab.focus -> select-window -t TID.
    #[test]
    fn tab_focus_translates_to_select_window() {
        use super::translate::{translate_request, TranslateOutcome};

        let request_json = r#"{
            "id": "22",
            "method": "tab.focus",
            "params": { "tab_id": "@3" }
        }"#;
        let argv = match translate_request(request_json).expect("tab.focus translates") {
            TranslateOutcome::RunTmux(a) => a,
            other => panic!("expected RunTmux, got {other:?}"),
        };
        assert_eq!(argv, vec!["select-window", "-t", "@3"]);
    }

    // L4d: tab.list shape parses tab-separated window lines.
    #[test]
    fn shape_tab_list_response_parses_window_lines() {
        use super::tmux_response::shape_response_with_params;

        let stdout = "@0\t0\twork\t1\n@5\t1\tlogs\t0\n";
        let params = serde_json::json!({"workspace_id": "$0"});
        let resp = shape_response_with_params("tab.list", serde_json::json!("23"), stdout, &params)
            .expect("shape ok");

        assert_eq!(
            resp.result,
            serde_json::json!({
                "workspace_id": "$0",
                "tabs": [
                    {"tab_id": "@0", "index": 0, "name": "work", "active": true},
                    {"tab_id": "@5", "index": 1, "name": "logs", "active": false},
                ]
            })
        );
    }

    // L3a: walk_split_path navigates the BSP projection of a
    // tmux layout. Empty path on a 2-child h-split returns the
    // root split's info: horizontal direction, total dim along
    // x, leftmost-pane = first child's pane id.
    #[test]
    fn walk_split_path_root_h_split() {
        use super::bsp::{walk_split_path, BspSplitDirection};
        use super::parse::parse_layout;

        let tree = parse_layout("abcd,80x24,0,0{40x24,0,0,1,39x24,41,0,2}").unwrap();
        let target = walk_split_path(&tree, &[]).expect("path resolves");
        assert_eq!(target.direction, BspSplitDirection::Horizontal);
        assert_eq!(target.leftmost_first_pane_id, "%1");
        assert_eq!(target.total_dim, 79); // 40 + 39
    }

    // L3b: a path leading into the right subtree of a 3-child
    // h-split lands on the inner binary split spanning child[1]
    // and child[2]. Direction is preserved; total_dim covers
    // the two remaining children.
    #[test]
    fn walk_split_path_into_right_chain() {
        use super::bsp::{walk_split_path, BspSplitDirection};
        use super::parse::parse_layout;

        // 3 columns: 26 / 26 / 26 (with two divider cells).
        let tree = parse_layout("1111,80x24,0,0{26x24,0,0,1,26x24,27,0,2,26x24,54,0,3}").unwrap();
        let target = walk_split_path(&tree, &[true]).expect("right path resolves");
        assert_eq!(target.direction, BspSplitDirection::Horizontal);
        assert_eq!(target.leftmost_first_pane_id, "%2");
        assert_eq!(target.total_dim, 52); // 26 + 26
    }

    // L3c: walking past the tree returns None.
    #[test]
    fn walk_split_path_off_tree_returns_none() {
        use super::bsp::walk_split_path;
        use super::parse::parse_layout;

        let tree = parse_layout("0000,80x24,0,0,1").unwrap();
        // Single-pane tree has no splits.
        assert!(walk_split_path(&tree, &[]).is_none());
        assert!(walk_split_path(&tree, &[false]).is_none());
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

    // B0: cmux-side client bytes (keyboard input, paste blob,
    // anything) must reach the tmux pane intact. Shell argv can
    // not carry NUL bytes safely, so we encode every byte as a
    // pair of hex digits and ship them via `send-keys -H`. The
    // round-trip (bytes -> argv -> bytes) must recover the input
    // verbatim, including binary, UTF-8 multibyte, and ESC.
    #[test]
    fn client_input_bytes_round_trip_through_send_keys_argv() {
        use super::pty::{bytes_to_send_keys_argv, send_keys_argv_to_bytes};

        let cases: Vec<&[u8]> = vec![b"hello", b"\x00\x01\x02\x1b[A", "日本語".as_bytes(), b""];

        for bytes in cases {
            let argv = bytes_to_send_keys_argv("%3", bytes);
            let recovered = send_keys_argv_to_bytes(&argv).expect("argv parses back to bytes");
            assert_eq!(recovered, bytes, "round-trip lost data for {bytes:?}");
        }

        // Sanity-check the argv shape for one concrete case.
        let argv = bytes_to_send_keys_argv("%3", b"AB\x1b");
        assert_eq!(argv, vec!["send-keys", "-t", "%3", "-H", "41", "42", "1b"]);
    }

    // B1: tmux ships pane output via `%output %<pane> <text>`
    // where bytes outside printable ASCII (and the backslash
    // itself) are octal-escaped as `\NNN`. The shim decodes that
    // back to raw bytes for the `raw-pty-attach` byte stream.
    #[test]
    fn tmux_output_event_decodes_and_forwards_bytes() {
        use super::pty::decode_output_event;

        let (pane, bytes) = decode_output_event("%output %3 hello\\012world").expect("decodes");
        assert_eq!(pane, "%3");
        assert_eq!(bytes, b"hello\nworld");

        // ESC + CSI sequence: `\033[A` is up-arrow.
        let (pane, bytes) = decode_output_event("%output %7 \\033[A").expect("decodes");
        assert_eq!(pane, "%7");
        assert_eq!(bytes, b"\x1b[A");

        // Literal backslash escapes as `\134` (octal for 0x5C).
        let (pane, bytes) = decode_output_event("%output %1 a\\134b").expect("decodes");
        assert_eq!(pane, "%1");
        assert_eq!(bytes, b"a\\b");

        // Lines that aren't %output return None.
        assert!(decode_output_event("%layout-change @0 1234,80x24,0,0,1").is_none());
    }

    // B2: realistic ANSI / CSI / OSC sequences must survive the
    // %output escape boundary byte-for-byte. Anything that gets
    // mangled here breaks colour, cursor positioning, OSC 7 cwd
    // tracking, and bracketed paste on reattach.
    #[test]
    fn output_with_escape_sequences_unmangled() {
        use super::pty::decode_output_event;

        let cases: &[(&str, &[u8])] = &[
            // SGR red, content, reset.
            ("\\033[31mfoo\\033[0m", b"\x1b[31mfoo\x1b[0m"),
            // OSC 7 (working directory) with BEL terminator.
            (
                "\\033]7;file://host/work\\007",
                b"\x1b]7;file://host/work\x07",
            ),
            // OSC 7 with ST (\\033\\\\).
            (
                "\\033]7;file://host/x\\033\\134",
                b"\x1b]7;file://host/x\x1b\\",
            ),
            // DECSET show cursor.
            ("\\033[?25h", b"\x1b[?25h"),
            // 24-bit colour SGR.
            (
                "\\033[38;2;255;128;0mX\\033[0m",
                b"\x1b[38;2;255;128;0mX\x1b[0m",
            ),
            // Tab + LF + DEL.
            ("\\011\\012\\177", b"\t\n\x7f"),
            // Bracketed paste begin / end.
            ("\\033[200~paste\\033[201~", b"\x1b[200~paste\x1b[201~"),
        ];

        for (escaped, expected) in cases {
            let line = format!("%output %4 {escaped}");
            let (pane, bytes) =
                decode_output_event(&line).unwrap_or_else(|| panic!("decode failed for {line:?}"));
            assert_eq!(pane, "%4");
            assert_eq!(bytes, *expected, "input {escaped:?}");
        }
    }

    // P3a: parse a leaf layout string into a Leaf node. Layout
    // grammar: `<checksum>,WxH,X,Y,paneN`. tmux stores pane ids as
    // bare integers; the shim normalises to the cmux pane id form
    // `%N` so downstream code never has to special-case.
    #[test]
    fn parse_layout_string_to_herdr_tree_leaf() {
        use super::parse::{parse_layout, Geometry, LayoutNode};

        let tree = parse_layout("1234,80x24,0,0,1").expect("leaf layout parses");

        match tree {
            LayoutNode::Leaf { geometry, pane_id } => {
                assert_eq!(
                    geometry,
                    Geometry {
                        w: 80,
                        h: 24,
                        x: 0,
                        y: 0
                    }
                );
                assert_eq!(pane_id, "%1");
            }
            other => panic!("expected Leaf, got {other:?}"),
        }
    }

    // P3b: tmux's left-right split syntax `{...}` becomes a
    // LeftRight node with each comma-separated child parsed
    // recursively.
    #[test]
    fn parse_layout_string_to_herdr_tree_left_right() {
        use super::parse::{parse_layout, LayoutNode, Orientation};

        let tree = parse_layout("abcd,80x24,0,0{40x24,0,0,1,40x24,40,0,2}")
            .expect("left-right layout parses");

        match tree {
            LayoutNode::Split {
                orientation,
                children,
                ..
            } => {
                assert_eq!(orientation, Orientation::LeftRight);
                assert_eq!(children.len(), 2);
                let leaves: Vec<&str> = children
                    .iter()
                    .map(|c| match c {
                        LayoutNode::Leaf { pane_id, .. } => pane_id.as_str(),
                        _ => panic!("expected Leaf child"),
                    })
                    .collect();
                assert_eq!(leaves, vec!["%1", "%2"]);
            }
            other => panic!("expected Split, got {other:?}"),
        }
    }

    // P3c: top-bottom syntax `[...]`.
    #[test]
    fn parse_layout_string_to_herdr_tree_top_bottom() {
        use super::parse::{parse_layout, LayoutNode, Orientation};

        let tree = parse_layout("ef01,80x24,0,0[80x12,0,0,1,80x12,0,12,2]")
            .expect("top-bottom layout parses");

        match tree {
            LayoutNode::Split {
                orientation,
                children,
                ..
            } => {
                assert_eq!(orientation, Orientation::TopBottom);
                assert_eq!(children.len(), 2);
            }
            other => panic!("expected Split, got {other:?}"),
        }
    }
}

#[cfg(test)]
mod proptests {
    use super::parse::{Geometry, LayoutNode, Orientation};
    use super::translate::{translate_request, translate_request_in_context, TranslateContext};
    use proptest::prelude::*;
    use proptest::test_runner::TestCaseError;

    fn arb_geometry() -> impl Strategy<Value = Geometry> {
        (1u32..1_000, 1u32..1_000, 0u32..1_000, 0u32..1_000).prop_map(|(w, h, x, y)| Geometry {
            w,
            h,
            x,
            y,
        })
    }

    fn arb_pane_id() -> impl Strategy<Value = String> {
        (1u32..10_000).prop_map(|n| format!("%{n}"))
    }

    fn arb_layout_node(max_depth: u32) -> impl Strategy<Value = LayoutNode> {
        let leaf = (arb_geometry(), arb_pane_id())
            .prop_map(|(geometry, pane_id)| LayoutNode::Leaf { geometry, pane_id });
        leaf.prop_recursive(max_depth, 16, 4, |inner| {
            (
                arb_geometry(),
                prop_oneof![Just(Orientation::LeftRight), Just(Orientation::TopBottom)],
                proptest::collection::vec(inner, 2..4),
            )
                .prop_map(|(geometry, orientation, children)| LayoutNode::Split {
                    geometry,
                    orientation,
                    children,
                })
        })
    }

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

        // B3a: any byte sequence survives the send-keys argv
        // boundary intact.
        #[test]
        fn arbitrary_bytes_round_trip_send_keys(
            bytes in proptest::collection::vec(any::<u8>(), 0..256),
        ) {
            use super::pty::{bytes_to_send_keys_argv, send_keys_argv_to_bytes};
            let argv = bytes_to_send_keys_argv("%2", &bytes);
            if bytes.is_empty() {
                prop_assert!(argv.is_empty());
            } else {
                let recovered = send_keys_argv_to_bytes(&argv)
                    .map_err(|e| TestCaseError::fail(format!("decode failed: {e}")))?;
                prop_assert_eq!(recovered, bytes);
            }
        }

        // B3b: any byte sequence survives tmux's %output octal
        // escape boundary intact.
        #[test]
        fn arbitrary_bytes_round_trip_output_event(
            bytes in proptest::collection::vec(any::<u8>(), 0..256),
        ) {
            use super::pty::{decode_output_event, encode_for_tmux_output};
            let line = format!("%output %5 {}", encode_for_tmux_output(&bytes));
            let (pane, recovered) = decode_output_event(&line)
                .ok_or_else(|| TestCaseError::fail(format!("decode None for {line:?}")))?;
            prop_assert_eq!(pane, "%5");
            prop_assert_eq!(recovered, bytes);
        }

        // P4: serialize then parse must be the identity for any
        // structurally valid LayoutNode tree. Geometric validity
        // (children sum to parent) is *not* enforced — tmux
        // itself doesn't reject non-summing trees on input, and
        // we round-trip the bits we receive.
        #[test]
        fn layout_strings_round_trip_through_tree(node in arb_layout_node(3)) {
            let s = super::parse::render_layout(&node);
            let parsed = super::parse::parse_layout(&s)
                .map_err(|e| TestCaseError::fail(format!("parse failed: {e} on {s:?}")))?;
            prop_assert_eq!(parsed, node);
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
