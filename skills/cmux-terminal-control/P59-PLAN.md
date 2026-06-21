# P59 — Merge upstream/main 34 commits (deferred)

Base: `c8b1d6cbe` (post-bonsplit catch-up). Goal: catch up upstream
34 commits while preserving cmux_term + chat_source.

## Why deferred

`-X theirs` merge of upstream produced silently corrupt
`Sources/TerminalController.swift`:
- Line 4282-4284 has orphan `@MainActor` followed by blank then code body,
  with no func signature — git's merge resolver kept upstream lines but
  ate the fork's `func v2WorkspaceSummaryPayload(...)` declaration that
  preceded the body.
- File ends at line 22885 with `}` at depth 1 (deinit outside class).
- No conflict markers — looks superficially clean. Building exposes
  20+ "expected declaration" errors on the corrupt section.

Pre-merge HEAD had `func v2WorkspaceSummaryPayload(workspace:index:selected:) -> [String: Any]`
at line 4285. Upstream restructured the same area entirely (different
methods, different bodies). `-X theirs` grabbed upstream's line set but
the line-anchored merge produced a Frankenstein.

## Step 1 — Take upstream's pbxproj wholesale + restore fork pkgs

Upstream wires all 35 P58 files. P58's pbxproj wiring is now redundant.

```bash
git checkout upstream/main -- cmux.xcodeproj/project.pbxproj
python3 /tmp/p58-add-pkgs3.py  # re-add CMUXSessionDaemon + CMUXSettingsCore
```

## Step 2 — Resolve TerminalController.swift manually

Two paths:
A) Take upstream's TerminalController.swift wholesale, then re-apply fork's
   v2-handler additions (cmux_term/screen_text/wait_for_text/wait_for_idle/
   screen_hash/wait_for_screen_change/tui_probe/wait_for_cursor handlers).
B) Take HEAD's TerminalController.swift wholesale, then port the 34 upstream
   commits' TerminalController changes one-by-one.

Path A is the standard "fork-rewrites-on-top-of-upstream" model and is
likely shorter; it's what we did successfully in P58.

## Step 3 — Other potentially-corrupted files

Run `swift -frontend -parse` on every modified .swift file to flush silent
corruption before reaching xcodebuild. Files merged with major upstream
changes:
- Sources/TerminalController.swift (already known corrupt)
- Sources/Workspace.swift (saw error at 558)
- Sources/AppDelegate.swift
- Sources/ContentView.swift (had extension_default branch issue in P58)

## Step 4 — Build green

The fork compiles clean at base `c8b1d6cbe`; corruption is purely a merge
artifact. After Step 2 fix, expect 5-15 small compile errors typical of
upstream API drift.

## Risk

- `-X theirs` is a footgun on heavily-rewritten files. Future merges should
  detect Frankensteins by parsing every modified .swift before committing.
- Manual TerminalController port preserves fork v2 handlers but is tedious.

## Status at deferral

- HEAD: `c8b1d6cbe`
- 1132 ahead / 34 behind upstream
- bonsplit submodule current
- Build green at base; merge attempt aborted

Next session: read this plan, follow Steps 1-4. Estimate: 1-2 hours of
focused merge work, similar effort to P58.
