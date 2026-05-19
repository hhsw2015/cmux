# Herdr Integration Architecture

Quick tour of the parts that make up cmux's herdr integration. Pair with
`herdr-integration-progress.md` (phase status + decision log) and
`herdr-spike-findings.md` (upstream protocol survey).

## Layers

```
                    ┌─────────────────────────────────────────────┐
   user actions →   │  Sidebar / Menu / Palette / Settings        │
                    └────────┬────────────────────────────────────┘
                             │
                    ┌────────▼─────────┐    ┌────────────────────┐
                    │  HerdrPanelOpener│    │ HerdrKillCommands  │
                    │  HerdrJumpCommands│   │ HerdrRemoteInstaller│
                    └────────┬─────────┘    └────────────────────┘
                             │
        ┌────────────────────┼────────────────────┐
        ▼                    ▼                    ▼
   ┌────────────┐    ┌───────────────┐    ┌──────────────────────┐
   │ HostRegistry│   │ HerdrTransport│    │ HerdrWorkspaceListStore│
   │ HerdrPersistence│ Factory       │    │ (per-host cache + diff) │
   └─────────────┘   └───────┬───────┘    └────────┬─────────────┘
                             │                      │
                ┌────────────┴────────┐             │
                ▼                     ▼             ▼
      ┌──────────────────┐  ┌────────────────┐  ┌──────────────┐
      │ LocalUDSTransport│  │ SSHStdioTransport│ │HerdrEventPump│
      │ (Unix socket)    │  │ (ssh + api-bridge)│ │(events.subscribe)│
      └──────────┬───────┘  └────────┬───────┘  └──────┬──────┘
                 └─────────┬──────────┘                 │
                           ▼                            │
              ┌─────────────────────────┐               │
              │       HerdrApiClient    │               │
              │  (JSON-RPC framing)     │               │
              └─────────────────────────┘               │
                                                        │
                          ┌─────────────────────────────┘
                          ▼
                 ┌────────────────┐
                 │  Renderers      │
                 │  HerdrInboundLayoutSync │
                 │  HerdrDividerSync       │
                 │  HerdrCloseHandler      │
                 │  HerdrSplitDispatcher   │
                 └─────────────────────────┘
```

## Data flow per scenario

### Open a herdr workspace

1. User triggers `HerdrPanelOpener.openWorkspace(host:)` (menu / palette / sidebar).
2. Existing-binding fast path: `HerdrTabRegistry.shared.allBindings` — if a binding for `(host, workspaceId)` already exists with a live `Workspace`, the matching `TabManager.selectedTabId` is set and we return.
3. Local binary check: `~/.local/bin/herdr-cmux` must exist (raw-pty-attach bridge).
4. Capability probe: `HerdrBackend.probeCapabilities()` calls ping + a bogus `layout.snapshot` to distinguish "method not found" from "tab not found". Incompatible → NSAlert.
5. Workspace selection:
   - explicit id → `workspace.get` to grab `active_tab_id`.
   - persisted entry → `resolvePersistedWorkspace` checks if the persisted (workspaceId, tabId) still exists.
   - else → first session.
6. `HerdrPanelOpener.wireHerdrBackedPanel` materializes a cmux pane:
   - opens a `HerdrApiClient` via `HerdrTransportFactory.make(host:)`.
   - calls `pane.attach` to get the `terminal_id`.
   - spawns `HerdrDisplayClient` (`herdr-cmux raw-pty-attach <terminal_id>` — over SSH for remote hosts).
   - wires PTY bytes through Ghostty's `GHOSTTY_SURFACE_IO_MANUAL` mode.
7. Records last-attached entry in `HerdrPersistence`.
8. Acquires the per-host `HerdrEventPump` so events stream in.

### Live update flow (agent goes blocked)

1. Remote agent transitions to blocked (herdr-side, not on the wire as an explicit event).
2. The 30s background poll (when cmux active) calls `HerdrWorkspaceListStore.refresh(host:)` per host.
3. Refresh runs `workspace.list` over the host's transport.
4. `detectAgentBlockedTransitions` diffs the new list against the cached one:
   - for each new blocked workspace → `postBlockedNotification` (UNUserNotification) + sidebar dot turns orange + badge count goes up.
   - for each blocked-→-non-blocked transition → `removeDeliveredNotifications` + dock badge updates.
5. `blockedCountChangedNotification` posts → `TerminalNotificationStore.refreshDockBadge` runs → cmux dock icon shows the combined unread number.

### Layout sync (drag a divider on Mac A, see it on Mac B)

1. User drags divider in cmux on Mac A.
2. Bonsplit emits `splitTabBar(_:didChangeGeometry:)` → `Workspace` calls `HerdrDividerSync.sync` with the bonsplit tree snapshot.
3. `HerdrDividerSync` diffs ratios against `lastSeen` map (epsilon 1e-3) and fires `pane.set_split_ratio` over the host's transport.
4. herdr daemon updates internal `TileLayout`, broadcasts `layout.changed` event.
5. On Mac B, `HerdrEventPump.handle` decodes payload → `HerdrInboundLayoutSync.apply`:
   - matching binding's leaves vs new spec → divider/structural/multi-add diff.
   - `setDividerPosition(fromExternal: true)` runs on bonsplit (50ms silence, no echo).
6. Mac B's local `lastSeen` is re-primed via `HerdrDividerSync.setLastSeen` so a future drag doesn't ping-pong.

## Files (Swift side)

- `Sources/HostRegistry/HerdrHost.swift` — host model (transport variant, session name).
- `Sources/HostRegistry/HostRegistry.swift` — persistent registry, localhost pinned at index 0.
- `Sources/HerdrTransport/HerdrTransport.swift` — protocol every transport conforms to.
- `Sources/HerdrTransport/LocalUDSTransport.swift` — Unix socket transport for localhost.
- `Sources/HerdrTransport/SSHStdioTransport.swift` — `ssh + api-bridge` transport for remote hosts; ControlMaster opts.
- `Sources/HerdrTransport/HerdrTransportFactory.swift` — picks transport by host.
- `Sources/HerdrClient/HerdrApiClient.swift` — JSON-RPC framing over a `HerdrTransport`.
- `Sources/HerdrClient/HerdrBackend.swift` — high-level RPCs + capability probe.
- `Sources/HerdrClient/HerdrLayoutTypes.swift` — wire DTOs for layout RPCs.
- `Sources/HerdrClient/HerdrLayoutSpec.swift` — cmux-typed layout + apply plan (slot-indexed, testable).
- `Sources/HerdrClient/HerdrTabRegistry.swift` — process-wide binding registry (`cmuxPaneId ↔ herdrPaneId`).
- `Sources/HerdrClient/HerdrPanelOpener.swift` — open / focus / wire workspaces.
- `Sources/HerdrClient/HerdrPanelRegistry.swift` — per-panel registry of attach state.
- `Sources/HerdrClient/HerdrSurfaceController.swift` — connects PTY bytes to Ghostty surface IO callbacks.
- `Sources/HerdrClient/HerdrDisplayClient.swift` — spawns `raw-pty-attach` subprocess, plumbs stdio.
- `Sources/HerdrClient/HerdrEventPump.swift` — long-lived `events.subscribe`, refcounted, auto-reconnect with backoff, connection state.
- `Sources/HerdrClient/HerdrInboundLayoutSync.swift` — applies remote `layout.changed` to bonsplit.
- `Sources/HerdrClient/HerdrDividerSync.swift` — outbound divider drag → `pane.set_split_ratio`.
- `Sources/HerdrClient/HerdrSplitDispatcher.swift` — outbound user-split → `pane.split`.
- `Sources/HerdrClient/HerdrCloseHandler.swift` — pane close ↔ `pane.close` (tmux detach semantics).
- `Sources/HerdrClient/HerdrOneShotRPC.swift` — fire-and-forget RPC helper.
- `Sources/HerdrClient/HerdrRemoteInstaller.swift` — scp+chmod+verify with notifications.
- `Sources/HerdrClient/HerdrPersistence.swift` — JSON-backed last-attached (workspaceId, tabId) per host.
- `Sources/HerdrClient/HerdrAutoReattach.swift` — launch hook that walks `HerdrPersistence`.
- `Sources/HerdrClient/HerdrWorkspaceListStore.swift` — per-host `workspace.list` cache, blocked-count, transition diff.
- `Sources/HerdrClient/HerdrNotificationSettings.swift` — `@AppStorage` knobs.
- `Sources/HerdrClient/HerdrKillCommands.swift` — `Kill Current Workspace` shared action.
- `Sources/HerdrClient/HerdrJumpCommands.swift` — included with HerdrKillCommands; `Jump to Next Blocked Workspace` round-robin.

## Files (UI side)

- `Sources/Sidebar/HerdrHostsSidebarSection.swift` — sidebar Herdr section.
- `Sources/Settings/HostsSettingsView.swift` — Settings → Hosts (add/edit/move/test).
- `Sources/cmuxApp.swift` — top-level `Herdr` menu (Cmd+Opt+H, Cmd+Opt+J, Cmd+Opt+Shift+K).
- `Sources/ContentViewHerdrCommands.swift` — command palette entries.

## Test files (`cmuxTests/`)

- `HerdrLayoutTypesTests.swift` — wire DTO Codable round-trips.
- `HerdrLayoutSpecTests.swift` — slot-indexed apply plan.
- `HerdrTabRegistryTests.swift` — binding lifecycle.
- `HerdrDividerSyncTests.swift` — outbound diff + epsilon.
- `HerdrPersistenceTests.swift` — JSON file persistence.
- `HerdrTransportFactoryTests.swift` — transport variant routing.
- `HerdrInboundLayoutSyncTests.swift` — pure tree walks (parent/findSplit/multi-add).
- `HerdrWorkspaceListStoreTests.swift` — agent_status transition diffs (blocked + resolved).
- `HerdrApiClientLiveTests.swift` — gated by `CMUX_HERDR_LIVE_SOCKET` env var; runs against a real daemon.

## Wire RPCs cmux speaks

cmux ↔ herdr daemon, all over JSON-RPC framed by `HerdrApiClient`:

- `ping`
- `workspace.create` / `workspace.list` / `workspace.get` / `workspace.rename` / `workspace.close` / `workspace.focus`
- `tab.create` / `tab.list` / `tab.get` / `tab.focus` (subset used)
- `pane.split` / `pane.list` / `pane.get` / `pane.close` / `pane.attach` / `pane.set_split_ratio` / `pane.swap` / `pane.focus` / `pane.resize`
- `layout.snapshot`
- `events.subscribe` (long-lived; cmux always subscribes to: `layout.changed`, `workspace.created/closed/focused/renamed`, `pane.exited`)

Every other RPC is one-shot — the daemon's API socket reads one line, dispatches, closes. Only `events.subscribe` keeps a long-lived connection.

## Three-layer state model

1. **Process state** (kernel) — PTY processes, owned by herdr daemon.
2. **Shared semantic state** (herdr) — workspaces, tabs, panes, layout (`TileLayout`), labels, focus, agent_status. Authoritative; cmux mirrors but doesn't own.
3. **Per-client UI state** (cmux local) — bonsplit geometry, theme, which workspace is currently shown, sidebar expansion, dock badge.

Anything in (2) flows through RPCs/events. Anything in (3) is `@AppStorage` / `@State` / `UserDefaults`.
