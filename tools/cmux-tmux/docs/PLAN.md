# cmux-tmux: design + TDD roadmap

This file is the source of truth for the cmux-tmux project. It is
written so a future session can resume implementation cold without
re-deriving any of the decisions below.

## Goal

Let cmux drive a tmux server as a pane backend, with feature parity
close enough to the existing herdr backend that a user with only
`tmux` installed on a remote host gets ~95% of the cmux experience.

## Why

cmux currently speaks one wire protocol — herdr's JSON-RPC + the
`raw-pty-attach` byte stream. herdr is a Rust multiplexer we
maintain. Lots of users already run tmux on their servers and don't
want to install a second daemon. cmux-tmux is the adapter that sits
on the remote host (or local) and presents itself to cmux as if it
were a herdr daemon, while internally driving tmux via control mode
+ `send-keys` + `pipe-pane`.

## Naming

- "**cmux pane protocol**" (a.k.a. CPP in code): the JSON-RPC + byte
  stream cmux speaks to a pane backend. herdr was the first
  implementation; cmux-tmux is the second.
- "**cmux-tmux**": this crate. Single binary. Speaks CPP on the
  cmux-facing side, tmux control mode on the tmux-facing side.

## Hard architectural rule (don't violate)

```
src/
  lib.rs                  ← pub mods only
  proto.rs                ← wire types (Request, Response, Event)
  translate.rs            ← CPP request → tmux argv (PURE)
  parse.rs                ← tmux output → CPP event   (PURE)
  bin/cmux-tmux.rs        ← only place that opens sockets / spawns tmux
tests/
  *.rs                    ← integration tests (spawn real tmux)
```

**Pure logic in `lib.rs`. I/O only in `bin/cmux-tmux.rs`.** Every
behavior testable as a sub-millisecond unit test that runs without
tmux installed and without spinning a real subprocess. The bin file
glues lib + I/O.

If a translation function reaches for `Command::new` or
`UnixListener`, it goes in the bin. If it does `String → Vec<String>`
or `Vec<u8> → Event`, it goes in the lib.

## CPP subset cmux actually uses (must implement)

Only methods cmux actually calls today (grepped from
`Sources/HerdrClient/*.swift`). Everything else is out of scope.

| method | direction | tmux equivalent | priority |
|---|---|---|---|
| `ping` | request/response | echo `pong` | P0 |
| `workspace.list` | r/r | `tmux list-sessions -F '#{session_id}\t#{session_name}'` | P0 |
| `workspace.create` | r/r | `tmux new-session -d -s NAME` | P0 |
| `workspace.attach` | r/r | mark session as cmux's current focus + return panes | P0 |
| `workspace.close` | r/r | `tmux kill-session -t SID` | P1 |
| `workspace.rename` | r/r | `tmux rename-session -t SID NAME` | P1 |
| `panes.list` | r/r | `tmux list-panes -t SID -F '#{pane_id}\t...'` | P0 |
| `pane.split` | r/r | `tmux split-window [-h\|-v] -c CWD -t TID` | P0 |
| `pane.resize` | r/r | `tmux resize-pane -x COLS -y ROWS -t TID` | P1 (lossy, see below) |
| `pane.set_split_ratio` | r/r | `tmux resize-pane -x N -t TID` (ratio→cells) | P1 (lossy) |
| `pane.focus` | r/r | `tmux select-pane -t TID` | P0 |
| `pane.close` | r/r | `tmux kill-pane -t TID` | P0 |
| `events.subscribe` | streaming | parse `tmux -CC` control mode events | P0 |
| `raw-pty-attach` (subcommand) | bidirectional bytes | `tmux pipe-pane -O 'cat >&FD'` + `send-keys -l` | P0 |

P0 = required for cmux to even open a session. P1 = needed for the
"feels right" experience.

## CPP events the shim must emit

Subscribed to via `events.subscribe`. Cmux side feeds these into
`HerdrEventPump`.

| CPP event | tmux source | notes |
|---|---|---|
| `layout_changed` | `%layout-change` | translate tmux's layout string to herdr tree shape |
| `pane_exited` | `%window-close` (rough) or `%session-changed` if last pane | tmux events not 1:1; map best-effort |
| `workspace_closed` | session ends | `%session-changed` to nothing |
| `tab.created/closed` | window create/destroy | tmux windows are cmux tabs |

## tmux mapping known-loss list (document, don't lie)

Things tmux's model can't express cleanly. Pin them so they can't
silently regress:

1. **Layout ratios are floats; tmux is integer cells.** Continuous
   60Hz divider drag mirrored from cmux to tmux quantizes. Acceptable
   for daily use; document.
2. **No per-pane raw byte history.** tmux only retains rendered
   text + scrollback. Cmux's `raw_pty_history` reattach replay
   rebuilt from `capture-pane -e` is approximate — alt-screen and
   bracketed-paste state can be wrong on reattach.
3. **No native `pane.exited` with exit code.** tmux fires
   `%window-close` after the process exits but the wire doesn't
   include the exit code unless you `display-message #{pane_dead_status}`
   right before the death; needs polling.
4. **Window vs session.** cmux's "workspace" maps to tmux session,
   "tab" maps to window. Hard-mapped, no flexibility.

## TDD roadmap (ordered, each step is one PR-sized commit)

Each step:
1. Write a failing unit test (RED).
2. `cargo test` and confirm RED.
3. Implement the minimum code to pass.
4. `cargo test` and confirm GREEN.
5. Refactor only if needed; tests stay GREEN.
6. Commit.

Run `cargo test` myself between each step. Do **not** push to the
user-facing build/install loop until a milestone check (M1, M2, M3
below) is hit.

### Stage 1 — pure translation layer (no tmux, no sockets)

| # | RED test | What this forces into existence |
|---|---|---|
| R0 | `pane_split_right_with_cwd_translates_to_tmux_argv` (already in `src/lib.rs`) | `translate::request_json_to_tmux_argv` parsing + dispatch + `pane.split → split-window` arm |
| R1 | `pane_split_down_translates_to_v_flag` | down-orientation arm |
| R2 | `ping_translates_to_no_tmux_call` (returns Ok(empty argv) + a synthesized Response) | request → `TranslateOutcome` enum with variants `RunTmux(Vec<String>)`, `ImmediateResponse(ResultResponse)`, `RunMulti(Vec<Vec<String>>)` |
| R3 | `panes_list_translates_to_list_panes` | `panes.list` → `list-panes -F '...'` |
| R4 | `workspace_list_translates_to_list_sessions` | `workspace.list` → `list-sessions -F '...'` |
| R5 | `pane_resize_translates_to_resize_pane` | size flags `-x`/`-y` |
| R6 | `pane_focus_translates_to_select_pane` | trivial |
| R7 | `pane_close_translates_to_kill_pane` | trivial |
| R8 | `set_split_ratio_translates_with_ratio_to_cells_conversion` | needs container size; first place the translate fn takes context (a `Workspace` snapshot) |
| R9 | `unknown_method_returns_method_not_found` | error envelope path |
| R10 | proptest: `arbitrary_json_request_never_panics` | resilience |

By end of stage 1: 100% of CPP request → tmux argv translation
covered. No tmux installed needed to run the suite.

### Stage 2 — pure parsing layer (tmux output → CPP events)

| # | RED test | What this forces |
|---|---|---|
| P0 | `parse_layout_change_event_emits_cpp_layout_changed` | `parse::tmux_line` returns enum; `%layout-change` arm |
| P1 | `parse_window_close_emits_pane_exited_for_each_owned_pane` | window→panes mapping requires state, so introduce `parse::Session` accumulator |
| P2 | `parse_session_changed_to_empty_emits_workspace_closed` | session-changed arm |
| P3 | `parse_layout_string_to_herdr_tree` | the actual `1234,80x24,0,0[40x24,0,0,1,40x24,40,0,2]` parser; standalone fn |
| P4 | proptest: `tmux_layout_strings_round_trip_through_tree` | layout serializer + parser closure |
| P5 | fixture corpus: drop 5-10 real `tmux -CC` recordings into `tests/fixtures/`, write a snapshot test that runs them through `parse::tmux_line` and asserts the emitted CPP event sequence | regression guard for the actual wire format |

### Stage 3 — `raw-pty-attach` byte plumbing (still pure)

The subcommand cmux spawns. Its job:
- read CPP control framing on stdin, forward decoded bytes to tmux
- read tmux pane output (via control mode `%output` events), encode
  as CPP raw bytes, write to stdout

These tests are about framing only; no real tmux yet.

| # | RED test | Forces |
|---|---|---|
| B0 | `client_input_bytes_round_trip_through_send_keys_argv` | escape rules, including binary/UTF-8/control chars |
| B1 | `tmux_output_event_decodes_and_forwards_bytes` | `%output %1 hex_str` parser |
| B2 | `output_with_escape_sequences_unmangled` | tmux's `%output` octal-escapes high bits; un-escape exactly |
| B3 | proptest: `arbitrary_byte_seq → send_keys_argv → recovered_bytes` | round-trip safety |

### Stage 4 — I/O layer (the bin)

Now the bin file wires translate + parse to real subprocess + sockets.
This is the part that needs real tmux.

| # | RED test | Forces |
|---|---|---|
| I0 | `tests/handshake.rs` — spawn shim against a fresh tmux server, send `ping`, expect `pong` | bin existence, socket listen, request dispatch, tmux exec wrapper |
| I1 | `tests/split.rs` — `workspace.create` then `pane.split` then `panes.list` returns 2 panes | end-to-end happy path |
| I2 | `tests/events.rs` — subscribe, then trigger a `pane.split`, expect a `layout_changed` event | event pump correctness |
| I3 | `tests/raw_pty.rs` — attach pane in a session running `cat`, write bytes to stdin, expect echo back | byte stream correctness over real tmux |
| I4 | `tests/restore.rs` — kill shim, reconnect, capture-pane buffer is replayed | reattach behavior |

CI runs these against tmux installed in a Linux Docker container.
Test runtime budget: <60s for full integration suite. Each test
uses a temp `TMUX_TMPDIR` for hermetic isolation.

### Stage 5 — cmux integration

Only after stage 4 is stable does cmux gain a new transport variant.
Even then, the change on cmux side is tiny: add `.tmuxControl` to
`HerdrHost.Transport` (or rename to `.cppTmux` if we generalize the
naming) + a connect-time check that the remote binary is `cmux-tmux`
not `herdr-cmux`.

Cmux-side test seam: `HerdrTransportFactory` already supports a
test-injectable transport. A python E2E test in `tests_v2/` can
drive cmux against a stubbed `cmux-tmux` to verify the same panel
mounts, splits, and resizes that herdr-backed E2Es cover.

## Milestones (when to push to user)

- **M1 (do not bother user)** — stage 1 + 2 complete, all green
  locally, ~50 unit tests passing in <2s. Push branch + open draft
  PR for review only.
- **M2 (do not bother user)** — stage 3 complete, raw-pty-attach
  byte translation 100% covered. CI green. Still no cmux integration.
- **M3 (lightly bother user)** — stage 4 complete, integration
  tests green against real tmux in CI. Can ship a `cmux-tmux` binary
  that a human (me, not the user) can manually drive: spawn it,
  shell out to it from a script, watch it work.
- **M4 (now ask user to test)** — stage 5 complete. cmux build with
  the new transport. User installs once and tries it on a real tmux
  host. By this point I should be 90% confident there are no
  freezes / UAFs / wedges, because every prior stage was green
  without their involvement.

## Self-test workflow (do not regress on this)

For each commit on this project:
1. `cd tools/cmux-tmux && cargo test`. Must be green.
2. If the change touches the bin or stage 4+, also `cargo test
   --test '*'` to run integration tests (real tmux).
3. `cargo clippy --all-targets -- -D warnings`. Must be green.
4. `cargo fmt --check`. Must be green.
5. Only then commit. Push only at milestone boundaries (M1, M2, M3,
   M4).

The user does **not** get pinged to install or click anything until
M4. Everything before M4 lives or dies on automated tests I run
myself.

## Open questions deferred

- Do we keep the protocol named "cmux pane protocol" or rename to
  something more neutral like "pmux protocol"? Defer until cmux side
  generalizes its `HerdrHost` types.
- Should cmux-tmux ship as a static binary fetched on first use, or
  expect the user to install it? Defer; herdr already has the
  download-on-first-use plumbing in
  `Sources/HerdrClient/HerdrRemoteInstaller.swift` so we can reuse.
- Does cmux-tmux need its own `--takeover` semantics for when two
  cmux instances connect to the same tmux session? Document as a
  TODO for stage 4.

## Current repo state (resume hint for next session)

Stages 1-4 complete; M1, M2, M3 all hit.

- `src/translate.rs`: full method dispatch (ping, events.subscribe,
  pane.split/resize/focus/close, panes.list, workspace.list/create/
  attach/close/rename, pane.set_split_ratio).
- `src/parse.rs`: `tmux_line` + `Session` accumulator + layout
  string parser/renderer round-trip.
- `src/pty.rs`: `bytes_to_send_keys_argv` + `decode_output_event` +
  `encode_for_tmux_output`, all proptest round-trip covered.
- `src/tmux_response.rs`: `shape_response_with_params` per method,
  `capture_args_for` for create-style methods, `event_to_json`.
- `src/bin/cmux-tmux.rs`: subcommands `serve` (JSON-RPC stdio +
  tmux -C event pump) and `raw-pty-attach --pane %N` (capture-pane
  replay + bidirectional bytes).
- `tests/`: 9 integration suites against real tmux, total ~6s.
- `.github/workflows/cmux-tmux.yml`: cargo fmt + clippy + test on
  Ubuntu with apt-get tmux.

What's left is M4: cmux-side Swift integration. Per the architectural
rule it's tiny — a new `HerdrHost.Transport` variant pointing at
`cmux-tmux serve` (control plane) and `cmux-tmux raw-pty-attach
--pane %N` (data plane). The CPP wire is already byte-compatible
with herdr's subset.
