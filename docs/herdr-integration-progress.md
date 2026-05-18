# Herdr Integration Progress

Saved: 2026-05-18

## Goal

Make cmux a "cross-machine agent workstation" where the Mac running cmux is one of N clients to herdr daemons (local + remote). cmux panels render herdr-managed PTYs directly through Ghostty so the experience is indistinguishable from a regular cmux terminal panel.

## Status

### Done

| Phase | What | Key commit |
|---|---|---|
| **H0 spike** | Verified herdr internals via fork+source review. Original blocker (no raw PTY) → solved by adding RawPty mode in fork. | `docs/herdr-spike-findings.md` |
| **Fork: RawPty** | `RenderEncoding::RawPty` + `ServerMessage::RawPtyChunk` + broadcast tap on `PaneRuntime` | hhsw2015/herdr@`7accd0c` |
| **Fork: smoke tests** | Input/resize/lifecycle round-trip tests | hhsw2015/herdr@`1c74a4f` |
| **Fork: raw-pty-attach CLI** | Stdio bridge subprocess so cmux Swift never touches bincode | hhsw2015/herdr@`972630c` |
| **Fork: pane.resize API** | `Method::PaneResize` JSON-RPC for embedder-driven PTY resize | hhsw2015/herdr@`ddeb99d` |
| **B1** HostRegistry + Settings UI | `Sources/HostRegistry/` + Settings page | `5c40617`, `2cc1d0c` |
| **B2** HerdrTransport (LocalUDS) | `Sources/HerdrTransport/` | `c38407b` |
| **B3** HerdrApiClient | Line-delimited JSON-RPC + events.subscribe | `b77d7f2` |
| **B4** HerdrDisplayClient | Subprocess bridge — spawns `herdr-cmux raw-pty-attach`, pipes bytes | `73b5061`, `46a22d0` |
| **B5** HerdrBackend | `SessionDaemonBackend` conformance, addressed per-host | `73125ab`, `0a44f7b` |
| **B6** HerdrSurfaceController | Pumps bytes between display client and Ghostty surface | `ed496d8`, `e64644e` |
| **C1** Debug verification window | `Debug → Debug Windows → Herdr Pane (debug)…` — hex dump + Ghostty preview | `744cb78` |
| **C2** Real Ghostty surface | `GHOSTTY_SURFACE_IO_MANUAL` + `io_write_cb` via `TerminalSurface.ExternalIoBinding` | `6f5521a`, `c2e530d` |
| **C3** PTY resize sync | `pane.resize` API + cmux hook (one-shot UDS per call due to herdr's one-line-then-close protocol) | `2a4f62b`, `f6ccf3e` |
| **C5** Open Herdr Panel via main path | `Debug → Debug Windows → Open Herdr Panel (localhost)` — opens a real cmux panel backed by herdr daemon | `b8f404d`, `5349ab0` |

### How to test

```bash
# 1. Build fork binary
cd /Users/wowdd1/Dev/herdr
PATH="$HOME/.local/bin:$PATH" cargo build --release --bin herdr
cp target/release/herdr ~/.local/bin/herdr-cmux

# 2. Start daemon + create workspace on it
~/.local/bin/herdr-cmux --session cmux-dev server &
~/.local/bin/herdr-cmux --session cmux-dev workspace create --label test

# 3. Build + launch cmux DEV
cd /Users/wowdd1/Dev/cmux
PATH="$HOME/.local/bin:$PATH" ./scripts/reload.sh --tag herdr --launch

# 4. In cmux DEV: Debug → Debug Windows → Open Herdr Panel (localhost)
#    A new tab opens, terminal renders herdr-managed PTY with full
#    cmux fidelity (font/transparency/blur/IME/keyboard/resize).
```

### Architecture (current)

```
cmux app (Mac, Swift)
├── HostRegistry       host list (localhost + remotes), Settings page
├── HerdrTransport     LocalUDSTransport (POSIX socket, async)
├── HerdrApiClient     line-delimited JSON-RPC over API socket
├── HerdrBackend       conforms to SessionDaemonBackend (per host)
├── HerdrDisplayClient spawns `herdr-cmux raw-pty-attach <id>` subprocess
├── HerdrSurfaceController  bridges subprocess stdout ↔ ghostty_surface_process_output
├── HerdrPanelRegistry maps cmux panelId → herdr-side resources
└── HerdrPanelOpener   builds binding, calls Workspace.newTerminalSurface(externalIo:)

cmux fork (hhsw2015/herdr, Rust)
├── server::protocol   RenderEncoding::RawPty, ServerMessage::RawPtyChunk
├── pane               broadcast::Sender<Bytes> tap from PTY reader
├── server::headless   spawn_raw_pty_forwarder per RawPty client
├── api::PaneResize    pane.resize { pane_id, cols, rows, cell_*_px }
└── cli::raw_pty_attach  stdio bridge subprocess for embedder GUIs
```

### Known issues / TODO

1. **Subprocess cleanup**: orphan `herdr-cmux raw-pty-attach` processes survive cmux DEV exit. We force `takeover=true` to win against them, but they should be reaped explicitly.
2. **Visual parity**: panel inherits Ghostty config (font, transparency, blur, theme) by virtue of using cmux's normal `TerminalSurface`/`TerminalPanel`/`bonsplit` chain. Confirmed working at user request.
3. **Resize lag**: small debounce (80 ms) means a rapid drag emits a few stale frames. Acceptable.

### Next steps (priority order)

| # | Step | Estimated effort |
|---|---|---|
| **C6** | SSH transport for remote hosts (was B7) — wraps `LocalUDSTransport` style flow over `ssh -T host`/ControlMaster. Unlocks "cross-machine agent workstation" goal. | 2-3 days |
| **C7** | Sidebar integration: surface remote host's sessions in the cmux sidebar so users can see/jump to remote panes from the workspace tree. | 1-2 days |
| **C8** | Auto-install herdr binary on remote when user adds a new host (one-click `curl install.sh`). | 0.5 day |
| **C9** | Replace Debug menu entry with a proper command-palette command + keyboard shortcut. | 0.5 day |
| **C10** | Drop the standalone debug window (`HerdrPaneDebugWindowController`) once C9 is in. | 0.25 day |
| **C11** | Capabilities probe: when a host is registered, query its herdr version + `pane.read --ansi` / `wait agent-status` / `pane.resize` support so the cmux UI can degrade gracefully. | 0.5 day |
| **C12** | Tests: add E2E test (CI) that spins up a fork daemon, opens a herdr panel via cmux, types into it, asserts bytes round-trip. | 1 day |

### Decision log

- **Fork over upstream PR** — user opted to maintain `hhsw2015/herdr` rather than upstream patches. AGPL terms acknowledged.
- **One-shot UDS per JSON-RPC call** — herdr's API socket reads one line, dispatches, closes. Long-lived connection only for `events.subscribe`. Resize requests open a fresh socket each time.
- **Subprocess bridge instead of in-Swift bincode** — the display socket uses bincode (Rust-specific). Adding a `cmh raw-pty-attach` CLI in the fork is far cheaper than a bincode reimpl in Swift.
- **`takeover=true` always** — orphan subprocesses from prior cmux DEV launches hold the attach owner. Forcing takeover means we always win.
- **Resize observer on hostedView frame, not window** — `panel.surface.hostedView.window` is nil at install time (bonsplit mounts on next runloop tick). `frameDidChange` on the view itself fires regardless of when it enters a window.

## Resuming

The next session should:
1. Read this doc.
2. Read `docs/herdr-spike-findings.md` for the original protocol survey.
3. Pick C6 (SSH transport) for the biggest user-facing win, or C9-C10 for cleanup.
