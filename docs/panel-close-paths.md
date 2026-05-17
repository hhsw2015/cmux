# Panel close paths — audit

Phase 2.1 deliverable. Maps every cmux entry point that destroys a terminal
panel so Phase 2.2's chokepoint can intercept them all.

## Existing chokepoint

```
all close paths
        │
        ▼
  Workspace.closePanel(panelId, force:)
        │
        ▼
  Workspace.requestCloseTab(tabId, force:)
        │
        ▼
  bonsplit close handler
        │
        ▼
  Workspace.discardClosedPanelLifecycleState(...)
        │
        ▼
  panel?.close()                          ← TerminalPanel.close()
  panels.removeValue(forKey: panelId)
```

`discardClosedPanelLifecycleState` runs **after** bonsplit accepts the close
and is the single point where cmux owns post-removal cleanup. Phase 2.2
will hook the keep-alive branch here.

## Public callers of closePanel

| Caller | Reason kind |
|--------|-------------|
| `Cmd+W` shortcut → CommandPaletteHandlers | userExplicit |
| Right-click "Close" → ContentView menu | userExplicit |
| Workspace deletion → Workspace.swift:845 | parentRemoved |
| Pane folding when last child closed → Workspace.swift:1228, 1249 | parentRemoved |
| Browser panel cleanup → Workspace.swift:8486 | automated |
| AppleScript `close terminal` → AppleScriptSupport | userExplicit |
| TerminalController socket cmd panel.close → 5941, 6484 | userExplicit |
| Drag-target placeholder cleanup → 8007, 8010 | automated |

## Direct callers of discardClosedPanelLifecycleState

| Caller | Reason kind |
|--------|-------------|
| `Workspace.swift:11407` (post-tab-close delegate) | inherits caller |
| `Workspace.swift:14562` (workspace teardown) | parentRemoved |
| `Workspace.swift:14721` (transferred remote cleanup) | automated |

## Bonsplit close routing

bonsplit doesn't synthesize closes on its own — every visible "X" or
keyboard close routes through `requestCloseTab` first. Drag-and-drop reorders
don't destroy panels, only the underlying transferred-tab cleanup at
14721 does.

## TerminalPanel.close() callers

| Caller | Notes |
|--------|-------|
| `Workspace+PanelLifecycle.swift:179` | inside `discardClosedPanelLifecycleState` (the chokepoint). |
| `DockPanelView.swift:132` | replaces an old dock-bound panel; not a session-bearing terminal panel today, but Phase 2.2 should still route through the chokepoint to be safe. |

## App-quit path

`AppDelegate.applicationWillTerminate` triggers
`Workspace.saveSessionSnapshot()` then lets ARC tear panels down. No explicit
close. **Implication:** keep-alive panels staying alive across quit happens
naturally (we never call `panel.close()`). Quit doesn't need any keep-alive
gating.

## Conclusion

cmux already has a single chokepoint
(`discardClosedPanelLifecycleState`). Phase 2.2 only needs to:

1. Add a `ClosePanelReason` parameter (default `.automated`) to
   `discardClosedPanelLifecycleState`.
2. Update `closePanel` / `requestCloseTab` to forward the reason.
3. Add `keepAlive` semantics inside the chokepoint:
   ```
   if panel.keepAlive && reason ∉ {userTerminate, parentRemoved} {
       detachOnly()
   } else {
       panel.close(); panels.removeValue(forKey:)
   }
   ```

No new chokepoint to introduce; existing one is solid.

## Lint to keep it solid

Add a CI check that fails if any new `panels.removeValue(forKey:)` or
`<panel>.close()` appears outside the two existing call sites. Phase 2.2
will land that check.
