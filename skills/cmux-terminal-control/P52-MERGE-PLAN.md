# P52 — Merge upstream/main into fork (30 commits behind)

Base: P50 = `4035f6bf0` (0.66.3/101). Goal: catch up upstream while preserving:

- All `cmux_term` socket handlers (`surface.snapshot`/`screen_text`/`wait_for_text`/`tui_probe`/etc)
- agent-bus dispatch (`notification.create` with `$bus`)
- TerminalSurface init in `Sources/GhosttyTerminalView.swift` (visibleSnapshot, processHasExited)
- skills/cmux-terminal-control/* (Python lib + ORCHESTRATOR_TEMPLATE.md)

## Step 1 — Merge with theirs preference

```bash
git merge --no-commit --no-ff -X theirs upstream/main
```

Expected: 0 unmerged conflicts (-X theirs takes upstream when overlap). 260+ files staged.

## Step 2 — Fix TerminalController.swift (orphan bodies + missing fns)

Upstream removed `v2WorkspaceCreate` body and `v2WorkspaceMoveToWindow` body when ControlCommandCoordinator was extracted. Fork still calls them in `v2MobileWorkspaceCreate`.

After merge, `func v2WorkspaceMoveToWindow(...)` and `func v2WorkspaceCreate(...)` become empty/orphaned. Restore from `4035f6bf0`:

```bash
# Extract bodies from P50
git show 4035f6bf0:Sources/TerminalController.swift | awk '/^    func v2WorkspaceCreate\(/{flag=1} flag {print; if(flag>1 && /^    \}$/) {flag=0; exit} else if(flag) flag++}' > /tmp/v2WC.swift
git show 4035f6bf0:Sources/TerminalController.swift | awk '/^    func v2WorkspaceMoveToWindow\(/{flag=1} flag {print; if(flag>1 && /^    \}$/) {flag=0; exit} else if(flag) flag++}' > /tmp/v2MTW.swift
```

Then in TerminalController.swift:

1. Find duplicate `func v2WorkspaceCreate` (likely 2 copies post-merge). Delete the upstream-only one. Keep fork's full body.
2. Find duplicate `func workspaceCloseProtectedMessage`. Delete upstream's.
3. Replace empty `func v2WorkspaceMoveToWindow(...) -> V2CallResult {\n\n    func v2WorkspaceCreate(...)` pattern by inserting full body from `/tmp/v2MTW.swift`.

## Step 3 — Fix Workspace.swift fork-only stubs

Upstream changed signatures + removed stubs.

3a. `createReplacementTerminalPanel()` needs param:

```swift
func createReplacementTerminalPanel(in controller: BonsplitController? = nil) -> TerminalPanel {
    let targetController = controller ?? bonsplitController
    let targetPaneId = targetController.focusedPaneId ?? targetController.allPaneIds.first
    var replacementConfig = inheritedTerminalConfig(
        preferredPanelId: focusedPanelId,
        inPane: targetPaneId
    )
    // ... rest unchanged
```

3b. `remotePortScanningEnabledFromSettings` — UserDefaultsSettingsClient/SettingCatalog removed upstream:

```swift
static func remotePortScanningEnabledFromSettings(defaults: UserDefaults = .standard) -> Bool {
    return true  // Keep fork behavior; full UDSC migration deferred.
}
```

3c. `enum CustomTitleSource` — add `case herdrInbound`:

```swift
enum CustomTitleSource: String, Codable, Sendable {
    case user
    case auto
    case herdrInbound
}
```

3d. Strip `.rawValue` after `SurfaceKind.terminal` etc. (SurfaceKind became plain String):

```bash
sed -i.bak -E 's/SurfaceKind\.(terminal|browser|markdown|filePreview|rightSidebarTool|agentSession|project|extensionBrowser)\.rawValue/SurfaceKind.\1/g' Sources/Workspace.swift Sources/WorkspacePortalPaneDrop.swift
rm Sources/Workspace.swift.bak Sources/WorkspacePortalPaneDrop.swift.bak
```

## Step 4 — Fix ContentView.swift

4a. Add `import CmuxFoundation` (typealiases for WorkspaceMountPlan etc.).

4b. Delete local `enum ShortcutHintDebugSettings { ... }` (shadows package's struct):

```bash
awk '/^enum ShortcutHintDebugSettings \{/{flag=1;next} flag{if(/^}$/){flag=0;next};next} 1' Sources/ContentView.swift > /tmp/cv.tmp && mv /tmp/cv.tmp Sources/ContentView.swift
```

## Step 5 — Fix namespace-enum call sites

`SidebarDropPlanner` is now `enum` (namespace). `ShortcutHintDebugSettings` IS struct but has instance vars; some call sites use static now:

```bash
# SidebarDropPlanner is enum now → drop ()
for f in Sources/Sidebar/SidebarBonsplitTabWorkspaceDropOverlay.swift Sources/SidebarWorkspaceGroupHeaderView.swift Sources/ContentView.swift; do
  sed -i.bak 's/SidebarDropPlanner()\./SidebarDropPlanner./g' "$f" && rm "$f.bak"
done
```

ShortcutHintDebugSettings stays as `()` (struct with init).

## Step 6 — GhosttyConfig.swift static→instance

```bash
sed -i.bak 's/CmuxGhosttyConfigSettingEditor\.clampedSidebarFontSize/CmuxGhosttyConfigSettingEditor().clampedSidebarFontSize/g; s/CmuxGhosttyConfigSettingEditor\.clampedSurfaceTabBarFontSize/CmuxGhosttyConfigSettingEditor().clampedSurfaceTabBarFontSize/g; s/CmuxApplicationSupportDirectories\.userDirectories(environment: environment)/CmuxApplicationSupportDirectories(environment: environment).userDirectories/g' Sources/GhosttyConfig.swift
rm Sources/GhosttyConfig.swift.bak
```

## Step 7 — Drop InternalImportsByDefault from CmuxFeedback

`FeedbackComposerBridge` defines `openComposer(in: NSWindow? = NSApp.keyWindow ?? NSApp.mainWindow)`. With `InternalImportsByDefault`, NSApp default arg becomes inaccessible from cmux app target. Fix:

```bash
sed -i.bak '/InternalImportsByDefault/d' Packages/CmuxFeedback/Package.swift && rm Packages/CmuxFeedback/Package.swift.bak
for f in $(find Packages/CmuxFeedback/Sources -name "*.swift"); do
  sed -i.bak 's/^public import /import /g' "$f"; rm "$f.bak"
done
```

## Step 8 — Replace FeedbackComposerBridge() call sites (still needed even after step 7)

The default arg fix may not be enough. Add explicit shim file `Sources/FeedbackComposerBridge+Shim.swift`:

```swift
import AppKit
import CmuxFeedback
import Foundation

extension FeedbackComposerBridge {
    @MainActor
    public static func openFromHelpMenu(window: NSWindow) {
        let bridge = FeedbackComposerBridge(
            client: FeedbackComposerClient(),
            userDefaults: UserDefaults.standard
        )
        bridge.openComposer(in: window)
    }

    @MainActor
    public static func makeDefault() -> FeedbackComposerBridge {
        FeedbackComposerBridge(
            client: FeedbackComposerClient(),
            userDefaults: UserDefaults.standard
        )
    }
}
```

Then replace call sites:

```bash
for f in Sources/App/CmuxHelpCommands.swift Sources/TerminalController+ControlSystemContext.swift; do
  sed -i.bak 's/FeedbackComposerBridge()\.openComposer(in: \([^)]*\))/FeedbackComposerBridge.openFromHelpMenu(window: \1)/g' "$f"
  rm "$f.bak"
done
sed -i.bak 's/FeedbackComposerBridge()\.submit/FeedbackComposerBridge.makeDefault().submit/g' Sources/TerminalController.swift
rm Sources/TerminalController.swift.bak
```

## Step 9 — Wire all new Sources/.swift files into pbxproj

Upstream added many fork-only files (84+). Use this exact Python:

```python
# Python script wires all unwired .swift files in Sources/ into pbxproj
# Using 24-char IDs (matches Xcode pattern). Files with `+` in name need name= attr.
# See pbxproj editing pattern in P48-A handler restoration.
```

Critical: must use `name = "X+Y.swift"; path = "X+Y.swift";` (both quoted) for files with `+`. Without this, pbxproj parses fine but Xcode silently ignores them.

## Step 10 — Wire CMUXSessionDaemon package

If `import CMUXSessionDaemon` fails, add Package.swift refs to pbxproj mirroring CMUXWorkstream pattern (6 spots).

## Step 11 — Other namespace-enum / struct-init issues

These show up as build progresses. Pattern: `XYZ() cannot be constructed because no accessible initializers`. Fix:

- If type is `public enum` (namespace): drop `()`.
- If type is `public struct` with public init that has internal-type defaults: write a shim wrapper in Sources/, make explicit args.

Known affected types:
- `SidebarDropPlanner` → enum
- `SidebarTabDropIndicatorPredicate` → struct, but has `public init() {}`
- `ShortcutHintDebugSettings` → struct
- `ShortcutHintModifierPolicy` → struct
- `FeedbackComposerBridge` → struct (use shim)
- `FeedbackComposerClient` → struct
- `FeedbackComposerSettings` → struct

## Step 12 — Build + commit

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-p52 -onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
```

Single `derivedDataPath /tmp/cmux-p52` reused — DON'T use new path each time (90GB wasted in P52 attempt 1).

When green:

```bash
./scripts/bump-version.sh patch
git add -A
git commit -m "P52: merge upstream/main 30 commits + preserve cmux_term handlers"
git push origin main
```

## Critical: verify fork features intact

Before any commit:

```bash
grep -c "case \"surface.snapshot\"\|case \"surface.screen_text\"\|case \"surface.tui_probe\"\|case \"surface.wait_for_text\"\|case \"surface.screen_hash\"" Sources/TerminalController.swift  # expect ≥5
grep -c "func v2SurfaceSnapshot\|func v2SurfaceScreenText\|func v2SurfaceScreenHash\|func v2NotificationCreateBus" Sources/TerminalController.swift  # expect ≥4
ls skills/cmux-terminal-control/lib/cmux_term/*.py | wc -l  # expect 13
ls skills/cmux-terminal-control/ORCHESTRATOR_TEMPLATE.md  # must exist
grep -c "func visibleSnapshot\|func processHasExited" Sources/GhosttyTerminalView.swift  # expect 2
```

If ANY drops, abort and `git reset --hard 4035f6bf0`.
