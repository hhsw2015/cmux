---
name: cmux-herdr
description: Schedule herdr workspaces, tabs, and panes from inside a cmux-managed herdr session. Use when the user is working in a cmux pane backed by the herdr daemon and wants to orchestrate splits, swaps, focus moves, zoom, or tab reordering — either from the cmux GUI or by invoking the daemon directly via the bundled herdr-cmux CLI.
---

# cmux + herdr scheduling

cmux mirrors a herdr daemon's authoritative tile layout. The cmux UI (drag dividers, cmd-z to zoom, drag tabs) and the bundled `herdr-cmux` CLI both speak to the same daemon over a unix socket. Use this skill when the user wants you to drive that scheduling layer programmatically.

Before doing anything, check `HERDR_ENV=1`. If it is not set, the current pane is **not** a herdr-backed pane — fall back to whatever non-herdr workflow makes sense and stop using this skill. cmux's herdr-attached panes inherit `HERDR_ENV=1` and `HERDR_SOCKET_PATH` from the daemon automatically.

For the agent-facing CLI semantics (workspace/tab/pane/agent ops, status streams, `wait` commands), follow herdr's own `SKILL.md` shipped with the daemon. This file only covers the **scheduling** RPCs that cmux added on top.

## When to reach for the scheduling RPCs vs the GUI

The cmux GUI fires the same RPCs you would from the CLI; the source of truth is always the daemon. Reach for the CLI when you need:

- Deterministic placement before the user is at the keyboard (boot a workspace, split panes, focus the right one)
- Reordering tabs / swapping panes inside scripts or ci-driven setup
- Zooming a specific pane while leaving others untouched
- Resizing panes for a screencast or e2e test

Do **not** call these RPCs to mirror what the user just did manually — the daemon already broadcasts `LayoutChanged` and cmux follows it. Calling them from inside a `pane.focused` handler creates loops.

## Scheduling RPC surface

All methods are JSON-RPC over the daemon's unix socket. Use `herdr-cmux api-bridge` to talk to the local socket from a remote shell, or `herdr <subcommand>` for the convenience wrappers when running locally.

### `pane.split`

Split a pane left/right or up/down. Returns the new pane's id. Daemon emits `PaneCreated` + `LayoutChanged` after success.

```json
{"id":"split:1","method":"pane.split","params":{"target_pane_id":"<pane>","direction":"Right","focus":true}}
```

### `pane.close`

Close a pane. Last pane in a workspace closes the workspace too. Daemon emits `PaneClosed` (+ `WorkspaceClosed` if last) and `LayoutChanged` for non-last closes.

### `pane.set_split_ratio`

Move a single divider. `path` is the layout-tree path of the split; `ratio` is the target ratio for the first child. Use this instead of computing absolute pixel sizes — the daemon does the geometry.

```json
{"id":"ratio:1","method":"pane.set_split_ratio","params":{"workspace_id":"<ws>","tab_id":"<ws>:<n>","path":[0,1],"ratio":0.62}}
```

### `pane.swap`

Swap two panes inside the same tab. Errors with `swap_across_workspaces` / `swap_across_tabs` if the panes don't share a tab. Useful for "move my editor to the left half" after a split.

### `pane.focus`

Focus a pane. Side effect: switches the daemon's selected workspace and tab to the pane's owners and sets `mode = Terminal`. Returns the new focused `pane_info`.

### `pane.set_zoom`

Toggle a pane's zoom flag. `zoomed: true` zooms; `zoomed: false` unzooms. No-op if the tab has only one pane. Daemon emits `PaneZoomed` so all subscribers (other cmux instances, sidecar agents) follow.

### `pane.resize`

Re-resize a pane's PTY. Use only when the GUI lacks the right info (e.g. headless runners) — normally cmux drives this from `NSWindowResize`.

### `tab.reorder`

Reorder all tabs in a workspace by passing the new full ordering as `tab_ids: [...]`. The daemon validates the permutation (rejects unknown / duplicate ids) and emits `TabReordered`.

### `layout.snapshot`

Pull the daemon's current tree for a tab. Use this on attach / reattach to seed the local mirror before subscribing to `LayoutChanged`. Cmux runs this in `HerdrBackend` to detect daemon-version compatibility.

## Subscribing instead of polling

For long-running orchestration:

- `events.subscribe` with `LayoutChanged {}` to follow tree shape (after split/close/swap/ratio).
- `events.subscribe` with `PaneZoomed {}` to follow zoom state.
- `events.subscribe` with `TabReordered {}` to follow tab order.
- `events.subscribe` with `PaneAgentStatusChanged { pane_id: null }` (note: `null` = global) to receive every agent state transition across the daemon. Per-pane subscription (`pane_id: "<id>"`) polls a single pane and returns on first matching status.

Subscriptions default to live-only — the buffered tail from before subscription is **not** replayed. This is intentional: cmux reattach used to spend its first second re-animating the previous session's drags.

## Common pitfalls

- Calling `pane.set_split_ratio` with a `path` that no longer matches the tree (after a sibling close) returns `split_path_not_found`. Re-read `layout.snapshot` and recompute.
- `pane.swap` does not move panes across tabs. Use `tab.reorder` for tabs and `pane.split` + targeted close for moving a pane to another tab.
- `pane.focus` switches workspaces. If you only want to focus inside the current workspace, check `workspace.focus` first to avoid surprising the user.
- All ids are workspace-scoped: `<workspace_id>:<n>` for tabs, `<workspace_id>:<n>:<m>` for panes. Don't reuse pane ids across workspaces.

## Failure modes worth handling

- Daemon offline → CLI exits non-zero with `connect: ...`. cmux UI shows host-offline notification after 20s; in scripts, fall back to local-only behavior.
- `not_implemented` from `pane.set_zoom` / `layout.snapshot` / etc. means the daemon is stock upstream herdr without the cmux fork's RPCs — rebuild from `hhsw2015/herdr` master.
- `pane_not_found` after a successful split is usually a stale local cache; re-read `pane.list` to refresh.
