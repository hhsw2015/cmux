# tsm event API — discovery notes

Phase 1.1 deliverable. Documents what `tsm` (adibhanna/tsm) exposes to
external callers and the strategy cmux will use for state changes.

## Surface available today

### CLI subcommands

```
tsm                        # opens TUI
tsm attach [name]          # attach (creates if absent? confirmed: yes for tui flow)
tsm detach [name]          # detach all clients (or current via Ctrl+\)
tsm new <name> [cmd...]    # create + attach
tsm ls                     # list sessions, plain text
tsm rename <old> <new>
tsm kill [name...]
tsm palette / tsm p        # picker TUI
tsm wt ...                 # worktree subcommands (see below)
tsm mux ...                # workspace manifest subcommands (see below)
tsm doctor                 # diagnostics (live/stale sockets, daemon build, orphans)
tsm doctor clean-stale
tsm debug session <name>   # detailed state for one session
tsm claude-statusline      # consume Claude's statusline JSON
tsm config install [--force]
tsm version
```

### Worktree (`tsm wt`)

```
tsm wt                     # list worktrees
tsm wt <branch>            # switch
tsm wt add <branch...>     # create
tsm wt rm <branch...> [-f]
tsm wt move <branch> <path>
tsm wt prune
tsm wt tui
tsm wt --create            # interactive create
```

### Mux (`tsm mux`)

```
tsm mux open <workspace>
tsm mux split <dir> <session>
tsm mux tab new <session>
tsm mux save <workspace>
tsm mux restore <workspace>
tsm mux doctor <workspace>
tsm mux sidebar sync <workspace>
tsm mux last / next
tsm mux workspace [name]
tsm mux setup kitty
tsm mux status
```

### Short aliases (documented)

Only `p` for `palette`. **No** single-letter aliases for attach/detach/new/ls/kill.
This is the opposite of zmx. The cmux argv parser must NOT assume `tsm a foo`
is `tsm attach foo` — it's an unknown command.

### Per-session sockets

Each session gets its own Unix socket under `$TSM_DIR` (or default
`~/.local/share/tsm/sessions/`). Watching the directory with FSEvents/
DispatchSource is the cheapest way to detect create/delete events.

### Per-session sidecar files

`tsm claude-statusline` writes structured JSON to a sidecar next to each
session's socket. Watching these gives **agent state** without polling
`tsm ls`. Schema documented in tsm README under "claude-statusline".

## What's missing

| feature | status | impact |
|---------|--------|--------|
| `--json` output for `ls` | ❌ none | parse plain text or use `debug session` per name |
| daemon-side event subscribe | ❌ none | must poll or watch sockets |
| short aliases for attach etc. | ❌ none | parser only matches full names |
| structured output for `wt` / `mux` | ❌ none | parse plain text |
| pid + cmd + cwd for arbitrary session | ✅ via `tsm debug session` | per-name lookup, slow to enumerate |
| client count | ✅ (TUI shows ●1/○0) | but not exposed in plain `ls`; need `debug session` |

## cmux strategy

### Listing sessions

```
fast path:    tsm ls → split by line → name only
detailed:     tsm debug session <name> → parse the labelled fields
```

cmux's `TsmBackend.listSessions` will:
1. Run `tsm ls`, parse names.
2. Lazily call `tsm debug session <name>` only when full state is needed
   (e.g., sidebar Background section rendering).

### Detecting state changes (Phase 5)

Three layers, cheapest first:

1. **FSEvents on `$TSM_DIR/sessions/`**
   - `CFFileDescriptor` / `DispatchSource.makeFileSystemObjectSource`
   - Triggers on socket file create / delete → session create / kill
   - Latency: <100ms
2. **FSEvents on per-session sidecar files**
   - Triggers on agent state writes (Claude statusline updates)
   - Latency: <100ms
3. **3s polling fallback**
   - `tsm ls` diff every 3s
   - Catches anything FSEvents missed
   - Latency: ≤3s

This satisfies the Phase 5 contract (no socket subscribe API needed).

### Engine selection in resolver

`SessionDaemonResolver` picks tsm when user selects it AND `tsm` binary
is on PATH AND `tsm version` returns success. `TsmBackend.locateBinary()`
checks PATH + homebrew prefixes.

### Bundle ID isolation

cmux instance creates session names prefixed with bundle id:
```
cmux-<bundleSuffix>-<panelId>
```
where `bundleSuffix` is the last path component of `Bundle.main.bundleIdentifier`
(e.g., `app` for `com.cmuxterm.app`, `staging` for `com.cmuxterm.staging`).

This prevents two cmux instances from binding the same session name when
both the production and staging app run side by side.

## Summary

tsm is fully scriptable but offers no event protocol. cmux fills the gap
with FSEvents on the session directory + sidecars, with a polling fallback
for resilience. The CLI parser only needs to recognize full subcommand
names — no aliases beyond `p`/`palette` (which we don't track anyway).
