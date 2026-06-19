# P58 — Merge upstream/main 36 commits (deferred)

Base: `91bff8be0` (post-bonsplit-fill-tab catch-up). Goal: catch up upstream
36 commits while preserving cmux_term + chat_source.

## Why deferred

Upstream PR #6356 ("Consolidate 20 narrow micro-packages into their owning
domain packages") is the killer commit. It DELETES 20+ Swift packages,
moving their content into other packages. Fork-side `pbxproj` still
references all 20 packages by name. `-X theirs` merge produces empty
package directories (because git doesn't track empty dirs) plus stale
`XCLocalSwiftPackageReference` entries that won't resolve. Resolves to
"the package manifest cannot be accessed" for every consolidated package.

Affected packages (incomplete list, observed during merge attempt):
- CmuxTerminalServices
- CmuxIPCService
- CmuxBrowserPanel
- CmuxCommandPaletteUI
- CMUXAgentVault
- CmuxWorkspaceWindow
- CmuxTerminalEngine
- CmuxProcess
- CMUXWorkstream
- CMUXSettingsCore
- CMUXExtensionHostSupport
- CmuxWorkspaceNavigation
- CmuxFeedbackUI
- CmuxSession
- CMUXSessionDaemon
- CmuxBrowserImport
- CmuxWorkspaceCore
- CmuxTerminalCopyMode
- CMUXPasteboardFidelity
- CmuxFileWatch
- CmuxSocketControl
- CmuxFileOpen

## Step 1 — Merge with theirs

```bash
git merge --no-commit --no-ff -X theirs upstream/main
```

Expected: Single conflict on Packages/macOS/CmuxFeedbackUI/Package.swift
(deleted by upstream, modified by us). `git rm` it.

## Step 2 — Identify what each consolidated package became

For each empty Packages/macOS/X dir, find the upstream consolidation target
(grep PR #6356 commit + commits that follow). Map: old → new package.

```bash
# For each missing pkg, find its identifying type and where it landed:
git log upstream/main --diff-filter=D --name-only --pretty=format: \
  -- "Packages/macOS/$X/Sources/" | head
git log upstream/main --diff-filter=A --name-only --pretty=format: \
  -- "Packages/macOS/" | grep "$type" | head
```

Likely consolidations (need verification):
- CmuxIPCService → CmuxSocketControl?
- CmuxFileWatch → CmuxFoundation?
- CMUXSessionDaemon → CmuxSession?
- CmuxTerminalServices → CmuxTerminal?
- CmuxBrowserPanel → CmuxBrowser?
- CmuxBrowserImport → CmuxBrowser?
- CmuxCommandPaletteUI → CmuxCommandPalette?
- CmuxProcess → CmuxFoundation?
- CmuxWorkspaceWindow → CmuxWorkspaces?
- CmuxWorkspaceCore → CmuxWorkspaces?
- CmuxWorkspaceNavigation → CmuxWorkspaces?
- CmuxTerminalEngine → CmuxTerminal?
- CmuxTerminalCopyMode → CmuxTerminal?
- CMUXAgentVault → CMUXAgentLaunch?
- CMUXExtensionHostSupport → CmuxExtensionKit?
- CmuxFeedbackUI → CmuxFeedback?
- CMUXPasteboardFidelity → CmuxFoundation?
- CmuxFileOpen → CmuxFoundation? (or stayed)
- CMUXSettingsCore → CmuxSettings?
- CMUXWorkstream → CmuxWorkspaces?

## Step 3 — Update pbxproj

For each killed package:
1. Remove `XCLocalSwiftPackageReference` entry (search by package name)
2. Remove `XCSwiftPackageProductDependency` entry
3. Remove `productRef` references in `Frameworks` build phases
4. Remove from `packageProductDependencies` and `packageReferences` lists
5. Replace import statements in fork-only Sources/ files:
   `import CmuxIPCService` → `import CmuxSocketControl` (etc per map)

Use Python script (the workflow is mechanical but must be precise — each
consolidation is a multi-line replacement across 6+ pbxproj sections).

## Step 4 — Delete empty package dirs

```bash
rm -rf Packages/macOS/CmuxIPCService Packages/macOS/CmuxTerminalServices ...
rm -rf Packages/CMUXSessionDaemon Packages/CMUXSettingsCore  # were already moved
```

## Step 5 — Build, fix per-file errors

The mechanical pbxproj surgery should resolve the resolve-graph errors.
Then fork-only Sources/ files referencing types from killed packages will
fail at compile time. Fix each by updating the import to the new domain
package.

## Risk

- pbxproj editing is fragile; 5 stale dups in P56-V2 corrupted it (recovered
  via git checkout).
- Some types may have been DELETED upstream entirely (not relocated). Will
  surface as "cannot find type X in scope". Stub or delete callers.
- `cmux.xcworkspace/contents.xcworkspacedata` likely needs `python3
  scripts/check-workspace-package-groups.py --write` after package moves.

## Disk hygiene

Single derivedDataPath `/tmp/cmux-p58`. Don't create new dirs for retries.

## Fork features to verify intact

```bash
grep -c "func v2SurfaceSnapshot\|func v2SurfaceScreenText\|func v2SurfaceScreenHash\|func v2NotificationCreateBus\|func v2SurfaceTuiProbe\|func v2SurfaceWaitForText" Sources/TerminalController.swift  # expect 6
ls skills/cmux-terminal-control/lib/cmux_term/chat_source.py  # must exist
ls skills/cmux-terminal-control/lib/cmux_term/*.py | wc -l  # expect 14
grep -c "case herdrInbound" Sources/Workspace.swift  # expect 1
grep -c "func visibleSnapshot\|func processHasExited" Sources/GhosttyTerminalView.swift  # expect 2
```

## Status at deferral

- HEAD: `91bff8be0`
- 1128 ahead / 36 behind
- bonsplit submodule current and pushed
- Build is GREEN at `91bff8be0`

Next session entry: read this plan, follow Steps 1-5, expect a long
mechanical session of pbxproj surgery + import rewrites. Probably 200+
edits. Allocate fresh context.
