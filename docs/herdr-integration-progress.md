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

## Architecture principles (decided 2026-05-18)

After the recon of herdr's existing API surface, we settled on the following model. cmux is a **renderer** for state that lives authoritatively on the herdr daemon. cmux owns visuals; herdr owns truth.

### Three-layer state model

| Layer | Examples | Authority | Synced across cmux clients? |
|---|---|---|---|
| **Process state** | PTY, cwd, title, exit code, agent state, pane size | herdr | yes (only one process exists) |
| **Shared semantic state** | workspace/tab/pane existence, BSP layout per tab, labels, tab order, last-focused pane | herdr | yes |
| **Per-client UI state** | which workspace is currently visible in this cmux window, window geometry, sidebar visibility, font/theme/transparency | cmux local | no |

**Implication:** cmux's `bonsplit` tree is a **mirror** of herdr's `TileLayout`, not an independent source of truth. All layout mutations (split, drag divider, close, swap, reorder tab) round-trip through herdr RPC and the bonsplit tree updates from broadcast events. Optimistic local rendering + reconcile keeps the UI snappy on a local UDS daemon (round-trip < 1 ms).

### Close semantics — tmux as guiding principle

The whole point of tmux is **closing the UI does not kill the work**. cmux follows that: detach is the default, kill is explicit.

| User action | Default behavior | Explicit kill entry |
|---|---|---|
| Quit cmux app (Cmd+Q) | **detach all** — daemon keeps running, every workspace/tab/pane survives, next launch reattaches | none — quit must be side-effect-free |
| Close window (Cmd+Shift+W) | **detach this view of the workspace** | right-click / command palette: "Kill workspace" → `workspace.close` |
| Close tab (Cmd+W) | **detach the tab view** | "Kill tab" → `tab.close` (kills every pane in that tab) |
| Close panel (split) | **kill** — same as tmux, no concept of "hide one split" inside a BSP tree | n/a |

The split between "detach" and "kill" maps cleanly to the state-layer model: detach only mutates per-client UI state (this cmux stops rendering); kill issues an RPC that mutates herdr's authoritative state and broadcasts to every other client.

### Why Plan C (not Plan B)

We considered storing cmux's bonsplit tree as an opaque metadata blob in herdr (Plan B). Rejected because:

1. cmux is Mac-only — there is no second client kind whose layout would need to differ. Two clients = two Macs = same screen size = same layout is the right answer.
2. herdr **already has** an internal authoritative BSP tree (`src/layout.rs`: `Node::Split { direction, ratio, first, second }`). The work to build a parallel blob mechanism would duplicate state that already lives correctly server-side.
3. Single-source-of-truth gives "open second Mac → same workstation" for free, which is the headline goal of the integration.

Plan B's only advantage was upstream-friendliness, which we don't care about (we own the fork).

## Next steps (priority order)

The big chunk is **C5.5–C5.9: layout authority + tmux close semantics**. SSH and polish come after.

### Phase D — herdr fork: expose layout as authority

| # | Step | Effort |
|---|---|---|
| **D1** | Add `Node` wire DTO (`Pane(pane_id) \| Split { direction, ratio, first, second }`); use root-relative L/R **paths** to address splits (no stable split IDs needed). | 0.5 d |
| **D2** | Add `layout.snapshot(workspace_id, tab_id) -> Tree` RPC. | 0.5 d |
| **D3** | Add missing mutation RPCs: `pane.set_split_ratio { path, ratio }`, `pane.move { pane_id, target_pane_id, direction }`, `pane.swap { a, b }`, `pane.focus { pane_id }`, `tab.reorder { workspace_id, tab_ids }`. | 1.5 d |
| **D4** | Add events: `LayoutChanged { workspace_id, tab_id, tree }` (rebroadcasts the whole tree on any structural change — simpler than fine-grained deltas), `PaneMoved`, `TabReordered`. Reuse existing `PaneFocused` for D3's `pane.focus`. | 0.5 d |

Total fork: ~2-3 days, ~600-1000 LOC across `schema.rs`, `app/api.rs`, `layout.rs`, `events.rs`, `persist/`.

### Phase E — cmux: bonsplit ↔ TileLayout mirror

| # | Step | Effort |
|---|---|---|
| **E1** | Translator: herdr `Tree` → cmux `BonsplitNode`, and bonsplit operations → herdr RPCs. | 1 d |
| **E2** | Replace local-only bonsplit mutations on herdr-backed panels with optimistic-RPC pattern (apply locally, send RPC, reconcile from `LayoutChanged` event, rollback on failure). | 1 d |
| **E3** | Subscribe to `events.subscribe` per workspace: handle `PaneCreated/Closed/Renamed/Focused`, `TabCreated/Closed/Renamed/Focused/Reordered`, `WorkspaceRenamed/Focused`, `PaneAgentStatusChanged`, `LayoutChanged`. Plumb into existing tab title / breadcrumb / status sinks. | 1 d |
| **E4** | Persistence: cmux workspace JSON stores `{ host, workspace_id }` per cmux window, not the layout itself (layout comes from `layout.snapshot`). On launch, reattach to daemon, snapshot, render. | 0.5 d |
| **E5** | Close semantics implementation per the table above: Cmd+Q / Cmd+Shift+W / Cmd+W default to detach (UI-only); add explicit "Kill" entries; pane close maps to `pane.close` (kill). | 0.5 d |

Total cmux: ~4 days, ~400-600 LOC across `Sources/HerdrClient/`, `Sources/Workspace.swift`, bonsplit translator, persistence, close handlers.

### Phase F — remaining (was C6-C12, deprioritized below D/E)

| # | Step | Effort |
|---|---|---|
| **F1** (was C6) | SSH transport for remote hosts. | 2-3 d |
| **F2** (was C7) | Sidebar shows remote host's workspaces. | 1-2 d |
| **F3** (was C8) | Auto-install herdr binary on remote on host registration. | 0.5 d |
| **F4** (was C9) | Replace Debug menu entry with command-palette command + keyboard shortcut. | 0.5 d |
| **F5** (was C10) | Drop standalone debug window (`HerdrPaneDebugWindowController`). | 0.25 d |
| **F6** (was C11) | Capabilities probe per host (herdr version, optional method support). | 0.5 d |
| **F7** (was C12) | E2E CI test: fork daemon → open panel via cmux → type → assert round-trip. | 1 d |

### Decision log

- **Fork over upstream PR** — user opted to maintain `hhsw2015/herdr` rather than upstream patches. AGPL terms acknowledged.
- **Plan C over Plan B (2026-05-18)** — herdr is the layout authority; cmux's bonsplit mirrors `TileLayout`. cmux is Mac-only so device-divergence-of-layout was never a real argument.
- **tmux semantics for close (2026-05-18)** — detach default, kill explicit. Quit / close window / close tab default to detach; only `pane.close` and explicit "Kill" actions destroy state. See close-semantics table.
- **L/R path addressing for splits (2026-05-18)** — avoids inventing stable `SplitId`s in the fork; layout snapshot rebroadcast on every structural change covers the staleness window.
- **One-shot UDS per JSON-RPC call** — herdr's API socket reads one line, dispatches, closes. Long-lived connection only for `events.subscribe`. Resize requests open a fresh socket each time.
- **Subprocess bridge instead of in-Swift bincode** — the display socket uses bincode (Rust-specific). Adding a `cmh raw-pty-attach` CLI in the fork is far cheaper than a bincode reimpl in Swift.
- **`takeover=true` always** — orphan subprocesses from prior cmux DEV launches hold the attach owner. Forcing takeover means we always win.
- **Resize observer on hostedView frame, not window** — `panel.surface.hostedView.window` is nil at install time (bonsplit mounts on next runloop tick). `frameDidChange` on the view itself fires regardless of when it enters a window.

## Resuming

The next session should:
1. Read this doc — especially the Architecture principles and Close semantics tables.
2. Start phase D (herdr fork): D1 (Node wire DTO) → D2 (layout.snapshot) → D3 (mutation RPCs) → D4 (events).
3. Then phase E (cmux bonsplit mirror).
4. Phase F (SSH, polish) only after D/E land — without single-source-of-truth, remote hosts inherit a broken architecture.
