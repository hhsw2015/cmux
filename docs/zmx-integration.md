# zmx integration

Status: **MVP backbone landed; UI surfacing pending upstream review.**

[zmx](https://github.com/neurosnap/zmx) is a terminal session-persistence
daemon: shell processes survive a disconnect, scrollback included. cmux on its
own resumes only Claude / Codex / Cursor agent commands; this integration adds
zmx-backed PTY persistence so any panel command (zsh, vim, htop, log tails…)
can survive cmux restarts when the user explicitly opts into zmx.

## Design contract

cmux is a **passive observer**. It never wraps user commands automatically.
Tracking only kicks in when the user invokes `zmx attach <name>` (or its alias
`zmx a <name>`) on their own. Every other zmx subcommand
(`run`/`r`, `send`/`s`, `print`/`p`, `tail`/`t`, `history`/`hi`,
`detach`/`d`, `kill`/`k`, `list`/`l`/`ls`, `write`/`wr`, `wait`/`w`,
`completions`, `version`, `help`) is ignored — none of them represent a panel
"taking over" a session view.

## Components

```
Packages/CMUXZmx/
  ├─ ZmxLocator           // PATH + ~/.local/bin + homebrew discovery
  ├─ ZmxArgvParser        // recognise `zmx attach <name>` / `zmx a <name>`
  ├─ ZmxClient            // wrap `zmx ls --short` and `zmx kill`
  ├─ ProcessArgvReader    // KERN_PROCARGS2 sysctl for any pid's argv
  ├─ ZmxPanelDetector     // walk a panel's PTY descendants for live attaches
  ├─ ZmxSystemScanner     // sweep proc table for zmx attach invocations
  ├─ ZmxBindingIndex      // actor-backed JSON store (panel ↔ session)
  ├─ ZmxRestorePlanner    // pure decision table: attach / offer / clear / noop
  └─ RestorableZmxBinding // model + AttachState (attached / detached / lost)

Sources/ZmxCommandHooks.swift
  └─ MainActor bridge: listOrphanSessions / killSession / reconcile / isAvailable

Sources/AppDelegate.swift
  └─ applicationDidFinishLaunching → fire-and-forget ZmxCommandHooks.reconcile
```

## State machine

```
       user runs `zmx attach foo`
                │
                ▼
   ┌──────────────────────────┐
   │   AttachState.attached   │
   └──────────┬───────────────┘
              │ user `ctrl-\` or `zmx detach`
              ▼
   ┌──────────────────────────┐
   │   AttachState.detached   │
   └──────────┬───────────────┘
              │ session daemon dies / `zmx kill`
              ▼
   ┌──────────────────────────┐
   │     AttachState.lost     │
   └──────────────────────────┘
```

## Restore decision table

`ZmxRestorePlanner.plan(binding, environment)` is pure:

| binding | zmx binary | zmx executable | session alive | result |
|---------|-----------|----------------|---------------|--------|
| nil | — | — | — | `.noop` |
| any | missing | — | — | `.clearBinding(.zmxBinaryMissing)` |
| any | found | not exec | — | `.clearBinding(.zmxBinaryNotExecutable)` |
| any | OK | OK | no | `.clearBinding(.sessionNotAlive)` |
| `.attached` | OK | OK | yes | `.attach(argv, cwd)` |
| `.detached` | OK | OK | yes | `.offerReattach(binding)` |
| `.lost` | OK | OK | yes | `.offerReattach(binding)` |

## When zmx is not installed

`ZmxLocator.resolveBinary()` returns nil. Every entry point in
`ZmxCommandHooks` short-circuits without spawning subprocesses:

* `listOrphanSessions()` → `[]`
* `killSession(_:force:)` → `.failure(.zmxNotInstalled)`
* `reconcile()` → `[]` (no bindings flipped)
* `isAvailable()` → `false`

Existing bindings on disk are kept untouched so reinstalling zmx restores
the previous panel-to-session map. The launch reconcile becomes a no-op,
not a destructive sweep.

## Race protection

* `ZmxCommandHooks.runListAlive` returns nil on subprocess failure (timeout,
  daemon socket missing) so reconcile becomes a no-op when the daemon is
  transiently unavailable. Bindings are only flipped to `.lost` when zmx
  actually answered with an empty (or differing) session set.
* All subprocess work happens on `Task.detached(.utility)` — the main
  thread never blocks on `Process.waitUntilExit`.
* `ZmxBindingIndex.purge(sessionName:)` removes every panel binding for a
  given session in one critical section.

## Upstream PR plan

1. **Land package + bridge** (this branch) — no UI surface yet, zero risk
   to existing workflows.
2. **Wire palette** — add `palette.listOrphanZmxSessions`,
   `palette.killZmxSession`, `palette.reconcileZmxBindings` contributions in
   `ContentView.commandPaletteCommandContributions()`. Gate on
   `ZmxCommandHooks.isAvailable()`.
3. **Panel badge** — show a small ⚡ in the panel header when a binding
   exists; click → reattach for `.detached`, kill confirm for `.attached`.
4. **Settings panel** — surface zmx binary path detection + opt-in toggle.
5. **SSH/remote** — extend `ZmxClient` to dispatch through `cmuxd-remote`
   so a panel attached to a remote host can also persist via remote zmx.

## Tests

`swift test --package-path Packages/CMUXZmx` runs 32 unit tests covering
parser variants, locator paths, binding index round-trip + purge,
restore-planner decision branches, and process-table smoke checks. The
bridge file is exercised end-to-end the moment Phase 2 wires it into the
palette.
