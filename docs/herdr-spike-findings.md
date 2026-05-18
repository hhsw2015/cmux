# Herdr spike findings

Date: 2026-05-18
Repo SHA inspected: `fb94fff98dbcd88d9332a182dea4040c5de84fff`
Sources reviewed: README.md, SOCKET_API.md, SKILL.md, CONFIGURATION.md, LICENSE, src/api/schema.rs, src/api/mod.rs, src/server/protocol.rs, src/server/headless.rs, src/server/render_stream.rs, src/server/client_transport.rs, src/app/api.rs, src/app/agents.rs, src/detect.rs, src/remote.rs, src/persist.rs, src/persist/io.rs, src/persist/snapshot.rs, src/persist/restore.rs, src/session.rs

## Q1: Raw PTY byte stream over socket?

**Answer: NO.** Tmux-style control-mode design. Wire format is rendered output (semantic cell grid OR server-pre-encoded ANSI diffs), NOT raw PTY bytes.

Two distinct sockets:
1. **API/control socket** (`herdr.sock`) — JSON-RPC, never carries pane bytes.
2. **Display socket** (`herdr-client.sock`) — binary length-prefixed, used by herdr's own TUI client.

Evidence (`src/server/protocol.rs`):
- L34-41 — only two encodings supported:
```rust
pub enum RenderEncoding {
    SemanticFrame,    // cell-grid
    TerminalAnsi,     // server-diffed ANSI bytes
}
```
- L274-328 — `ServerMessage` variants for render channel: `Frame(FrameData)` (cell grid) and `Terminal(TerminalFrame)` (ANSI diff). NO `Bytes`/`PtyOutput`/`RawStream` variant.
- `src/server/render_stream.rs` L262-287 (`render_terminal_virtual`): server runs `ratatui::Terminal` with `TestBackend`, calls `runtime.render(...)`, captures buffer. Server is the emulator.

**Implication**: Cmux Ghostty cannot get raw PTY bytes from herdr. Best available is `TerminalAnsi` mode = server-pre-rendered ANSI diffs. Ghostty becomes passive ANSI sink, not authoritative emulator. Mouse, kitty kbd, OSC fidelity (cursor shape, OSC 52 clipboard, kitty graphics) all degraded.

## Q2: Multiple concurrent attach clients?

**Answer: PARTIAL.** No read-only observer attach. Second writable attach forces takeover (kicks existing). But ANY client can poll `pane.read` (Q6) and subscribe to events without affecting attach.

Evidence — `src/server/headless.rs` L1273-1295:
```rust
if let Some(existing_owner) = self.terminal_attach_owners.get(&terminal_id).copied() {
    if existing_owner != client_id && !takeover {
        // reject with "already has an attached client; retry with --takeover"
    }
    if existing_owner != client_id {
        // kick the previous owner
    }
}
```

No `observer|read_only` flag in attach code path.

**Implication**: cmux + ssh user attaching same pane = takeover war. Workaround = poll `pane.read` for non-primary view (not real-time, latency = poll interval).

## Q3: Capabilities / version negotiation?

**Answer: PARTIAL.** Version handshake exists but no feature-bit/capabilities map.

Evidence:
- `src/server/protocol.rs` L16: `pub const PROTOCOL_VERSION: u32 = 6;` (display socket)
- `Hello { version, cols, rows, cell_width_px, cell_height_px, requested_encoding }` → `Welcome { version, encoding, error }`. Server runs `protocol::check_client_version(version)`, rejects with error string.
- API socket: `ping` returns `pong { version: "0.1.2", protocol: 2 }`. Two protocol numbers tracked separately.
- `src/api/schema.rs` L11-91 — unknown method names produce serde parse errors, not structured `method_not_found`.

**Implication**: Hard-code minimum supported herdr version. No graceful capability degradation.

## Q4: Event stream API?

**Answer: YES.** `events.subscribe` is the headline API.

Evidence — `SOCKET_API.md` L795-870, `src/api/schema.rs` L313-361, L410-473:

Subscriptions (snake_case for base, dotted for parameterized):
- `workspace.created/closed/focused`
- `tab.created/closed/focused/renamed`
- `pane.created/closed/focused/exited`
- `pane.agent_detected`
- `pane.output_matched { pane_id, source, lines, match: Substring|Regex, strip_ansi }`
- `pane.agent_status_changed { pane_id, agent_status }`

Plus one-shot `events.wait { match_event, timeout_ms }` and server-side blocking `pane.wait_for_output {...}`.

**Implication**: Excellent fit. cmux opens long-lived API socket per herdr daemon, subscribes for full lifecycle + per-pane status.

## Q5: Pane creation parameters?

**Answer: WEAK.** No general `pane.create`. Panes born from `workspace.create` / `tab.create` / `pane.split` / `agent.start`. Only `cwd`, optional `label`, optional `agent` name, placement. **NO env vars. NO arbitrary metadata. NO arbitrary command for `pane.split` (always starts user's default shell).**

Evidence — `src/api/schema.rs`:
- L13-91 — no `pane.create` method exists
- `pane.split { workspace_id, target_pane_id, direction, cwd, focus }` (L200-217) — no `command`/`argv`/`env`
- `agent.start { name, cwd, workspace_id, tab_id, split, focus, argv }` (L184-198) — accepts `argv` but no `env`
- `PaneRenameParams` (L226-230) — only `label: Option<String>`
- `src/persist/snapshot.rs` L68-75 — `PaneSnapshot { cwd, label, agent_name }`. Only these survive snapshot.

**Implication**:
- Worktree binding: cmux must keep its own state, can't tag panes server-side (or hack into `label`).
- Env vars: no API. Workarounds = wrapper script in `argv`, or `pane.send_text "export FOO=bar; exec cmd"`.
- Arbitrary command for split: must be `agent.start` with custom `argv` or split-then-send-text dance.

## Q6: `pane read --ansi` from any client?

**Answer: YES.** Zero ownership/auth checks. Any API client can read any pane's text/ANSI from `visible`/`recent`/`recent_unwrapped`.

Evidence — `src/app/api.rs` L1183-1248: `Method::PaneRead` handler does pane lookup, then directly calls `pane.visible_ansi()` etc. No ownership check.

Lines capped at 1000 (L1219).

**Implication**: This is the **strongest lever for Option C** (cmux as herdr monitor). cmux can poll/subscribe and reconstruct pane content without owning, without conflicts, without disturbing herdr's TUI. Tradeoff: not real-time live keystroke echo; cursor/soft-wrap reflow degraded.

## Q7: Agent auto-detection mechanism

**Answer: TWO LAYERS** — process-name match + screen-content pattern matching.

Evidence — `src/detect.rs`:
- L20-34: 12 agents hardcoded: `Pi, Claude, Codex, Gemini, Cursor, Cline, OpenCode, GithubCopilot, Kimi, Droid, Amp, Grok`
- L74-92 (`identify_agent`): pure binary-name match against lowercase basename
- L94-111 (`identify_agent_in_job`): walks `ForegroundJob.processes`, picks highest-priority agent process
- L113-133 (`detect_state`): per-agent regex/pattern function over visible screen tail → `Idle/Working/Blocked/Unknown`

External integrations: `pane.report_agent { source, agent, state, message, custom_status }` (`schema.rs` L266-277). Authoritative override.

**Implication**: 12 agents free. Adding new agent = upstream patch OR call `pane.report_agent` from cmux helper.

## Q8: `--remote` transport

**Answer: SSH stdio bridge.** Each connection spawns `ssh -T <target>` running remote helper that proxies remote daemon's UNIX socket over stdio.

Evidence — `src/remote.rs`:
- L83-101 (`run_remote`): creates local socket, prepares/installs remote binary, starts `SshStdioBridge`, runs herdr client against local socket
- L653-680 (`bridge_connection`):
```rust
let mut command = Command::new("ssh");
command.arg("-T").arg(target).arg(remote_bridge_command(remote_herdr, session_name));
```
- L542-550 (`remote_bridge_command`): remote runs `exec ~/.local/bin/herdr [--session NAME] remote-client-bridge`
- L238-266 (`prepare_remote_herdr`): auto-installs binary via `uname` detection, downloads from manifest

Bridges **display socket**, not API socket. Same pattern works for API but no built-in helper command — would need to invoke api_socket directly.

**Implication**:
- Wire = SSH stdio. No port forwards needed. Corp-network friendly.
- Per-connection cost = ssh spawn. Need own ControlMaster multiplexing for cmux's many subscriptions.
- Auto-install of remote binary is opinionated. Cmux should disable + pin known version.

## Q9: Session vs pane vs workspace vs tab model

**Answer: 5-level hierarchy.** Session (server namespace) → Workspace (numbered, identity_cwd) → Tab → BSP layout → Pane → Terminal (PTY).

Evidence:
- `src/session.rs` — "session" = named server namespace (its own daemon, sockets, snapshot file). `default` reserved.
- `SessionSnapshot` → `WorkspaceSnapshot { id, custom_name, identity_cwd, tabs, active_tab }` → `TabSnapshot { custom_name, layout: LayoutSnapshot (BSP tree), panes: HashMap, zoomed, focused, root_pane }` → `PaneSnapshot { cwd, label, agent_name }`
- ID forms (`SOCKET_API.md` L79-106): workspace `w64e95948145ed1`, tab `w64e95948145ed1:1`, pane `w64e95948145ed1-1` (workspace-scoped, NOT tab-scoped).

**Implication**: 1 cmux app instance ↔ 1+ herdr sessions (e.g., `cmux-main` per app variant). cmux tabs ↔ herdr tabs. cmux workspaces ↔ herdr workspaces. cmux panes ↔ herdr panes 1:1. BSP layout in herdr is tab-scoped; cmux bonsplit must mirror or reskin.

## Q10: Persistence model

**Answer: Layout + cwd + label + agent_name only. PTY processes do NOT persist across server restart.**

Evidence:
- `src/persist.rs` L1-13: stored at `~/.config/herdr/session.json` (or `sessions/<name>/` for named).
- `src/persist/io.rs` L51-80: snapshot version = `3`. Atomic save via `*.tmp + rename`.
- `src/persist/restore.rs` L18: comment **"Each pane gets a fresh shell in its saved cwd."**
- L144-162: missing cwd falls back to `$HOME` then `/`.

**Implication**:
- Within running daemon: PTYs + scrollback preserved (normal detach/reattach).
- Daemon restart (crash/reboot/`server stop`): layout restored, processes NOT. Agent conversations die.
- cmux probably wants own sidecar persistence for cmux session ↔ herdr pane bindings.

## Q11: Install paths & multi-instance coexistence

**Answer: Fully namespaced via `--session <name>`.** Multiple cmux apps coexist.

Evidence — `SOCKET_API.md` L28-40 + `src/session.rs`:

Socket path resolution:
1. `--session <name>` → `~/.config/herdr/sessions/<name>/herdr.sock`
2. `HERDR_SOCKET_PATH` env override (exact)
3. `HERDR_SESSION=<name>` env → same as #1
4. Default → `~/.config/herdr/herdr.sock`

Display socket: `herdr-client.sock` in same dir; `HERDR_CLIENT_SOCKET_PATH` override.

Per-session state: `<data_dir>/session.json`.

Config: `~/.config/herdr/config.toml` is **global**, not session-namespaced.

**Implication**:
- cmux launches dedicated daemon: `cmux-main`, `cmux-staging`, `cmux-dev` per app variant
- cmux must pass `--session cmux-main` to every CLI/socket op (else pollutes user's `default`)
- Shared config.toml is minor wart

## Q12: License (AGPL-3.0)

**Answer: Cmux can wrap herdr over socket without absorbing AGPL into cmux's code, provided cmux uses unmodified upstream herdr.**

Evidence: plain AGPL-3.0, no linking exception in Cargo.toml.

Practical (per FSF AGPL FAQ, not legal advice):
- IPC over socket = NOT linking. cmux source not required to be AGPL.
- Distributing modified herdr binary = must offer modified source under AGPL.
- §13 network use: triggers if cmux operates herdr for users over network and modifies herdr.

**Implication**:
- Safe path: bundle/pin unmodified upstream. All cmux-side improvements over socket. No contagion.
- Need missing feature → upstream PR, or maintain public fork (fork's diff must be AGPL).

## Conceptual summary

Herdr = **tmux-control-mode-as-a-product**. Headless server owning PTYs + scrollback for many panes, two parallel UDS APIs:
- API socket (`herdr.sock`, line-delimited JSON-RPC): orchestration, lifecycle, `pane.read`, `pane.send_text`, `pane.wait_for_output`, `events.subscribe`, `agent.start`
- Display socket (`herdr-client.sock`, binary length-prefixed): herdr TUI's render channel; negotiates `SemanticFrame` cell-grid OR `TerminalAnsi` server-pre-encoded diff stream

NO raw-PTY-byte transport. Daemon runs terminal emulator internally; wire format always cooked.

Data model: Session (server namespace + persistence root) → Workspace (numbered, identity-cwd, cached git branch) → Tab → BSP layout of Panes → Terminal/PTY. Stable opaque IDs.

Persistence: JSON snapshot saving layout + per-pane cwd + label + agent_name. **PTYs NOT persisted across server restart** — each pane respawns fresh shell at saved cwd.

Agent identity: foreground process name match (`identify_agent_in_job` walks process group) + per-agent screen-tail pattern matchers in `src/detect.rs` for state classification. 12 agents native; extension via `pane.report_agent`.

Remote: `ssh -T <target> 'exec ~/.local/bin/herdr [--session NAME] remote-client-bridge'` + UNIX socket bridged through SSH stdio. Per-connection ssh spawn (need own ControlMaster). Auto-installs remote binary.

License: plain AGPL-3.0, no linking exception. Cmux stays clear via socket-only + unmodified upstream.

## Risk register update

| Goal | New risk | Severity |
|---|---|---|
| "Ghostty as renderer for herdr panes" | Herdr NEVER emits raw PTY. Best = `TerminalAnsi` (server-rendered diff). Ghostty = passive ANSI sink. Mouse/kitty kbd/OSC degraded. | **CRITICAL** |
| "Multi-machine, one cmux UI" | SSH-stdio per-connection. Need own ControlMaster. Disable + pin auto-install. | Medium |
| "Bind sessions to git worktrees via metadata" | No metadata API. Only `label`. Encode in label or keep entirely in cmux. | Medium |
| "Inject env vars into spawned panes" | No env API. Workarounds brittle. | Medium |
| "Two cmux clients observe one pane" | No read-only attach. Single-owner takeover. Polling `pane.read` works but not real-time. | Medium |
| "Agents resume across daemon restart" | PTYs not persisted; only layout + cwd. Conversations die on `server stop`. | Medium |
| "Capability negotiation" | None. Hard-code minimum version. | Low |
| "Subscribe to live events" | Fully supported. | Green |
| "Read screen any pane" | Fully supported. | Green |
| "Multi cmux variant coexist" | `--session <name>` per variant. Config.toml global wart. | Low |
| "AGPL contagion" | Safe via socket-only + unmodified upstream. Forking triggers AGPL on fork. | Low |
| "Add new agents" | Upstream patch OR `pane.report_agent` from cmux helper. | Low |
| "Spawn pane with arbitrary command" | No `command` on `pane.split`. Use `agent.start { argv }` or split-then-send-text. | Low |

## Recommendation

**No-go on Option B as currently framed** ("herdr backend with Ghostty rendering raw PTY bytes"). Q1 is fatal: herdr never exposes raw PTY streams.

**Realistic alternatives, preferred order:**

### Option B' — herdr-as-orchestrator, cmux-owned PTYs

cmux keeps spawning own PTYs locally + on remotes. Ghostty gets raw bytes. Use herdr only for:
- Process discovery
- Agent detection (call `pane.report_agent` from cmux to feed herdr's detector)
- Cross-machine session listing
- Headless companion on each machine for AI telemetry

Sacrifices "lift-and-shift any herdr session into cmux" but preserves Ghostty quality.

### Option C — herdr panes as monitoring view (recommended tracer bullet)

cmux primarily renders own PTYs (Ghostty). Sidebar/tab listing herdr panes from registered daemons, viewable through `pane.read --ansi` polling at 1-2 Hz. "Monitor your AI agents from cmux" feature, NOT full backend. Low risk, high value.

### Option B" — long-term, requires upstream

File issue + PR with `ogulcancelik/herdr` to add `RawPty` render encoding bypassing server emulator. Doable but slow; not under our timeline.

### Last resort: fork

Maintain cmux-specific herdr fork (AGPL public) with raw-PTY mode patched in. AGPL exposure for fork's diff.

**Recommended sequence**: Start with Option C as tracer (few hundred LOC API client on top of cmux), confirm value with users, escalate to Option B' for full integration. Avoid Option B unless upstream agrees to raw-PTY mode.
