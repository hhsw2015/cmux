# Fork Sync & Release Playbook

How to pull upstream changes into the hhsw2015 fork chain, build cmux locally, and publish a pre-release.

## Repository topology

```
hhsw2015/cmux                  ← top-level app (this repo)
├── ghostty       (submodule)  ← hhsw2015/ghostty   ← upstream manaflow-ai/ghostty
├── vendor/bonsplit (submodule) ← hhsw2015/bonsplit ← upstream manaflow-ai/bonsplit
└── (Rust dep)                  ← hhsw2015/herdr    ← upstream ogulcancelik/herdr  (separate clone at /Users/wowdd1/Dev/herdr)
```

Local checkouts:
- `/Users/wowdd1/Dev/cmux`             — main repo + 2 submodules
- `/Users/wowdd1/Dev/herdr`            — herdr fork (independent clone, not a submodule)
- `/Users/wowdd1/Dev/cmux/ghostty`     — ghostty submodule
- `/Users/wowdd1/Dev/cmux/vendor/bonsplit` — bonsplit submodule

## Sync order (bottom-up — submodules first)

Always merge dependencies before parent so the parent merge can pin the new submodule SHAs in one commit.

1. **bonsplit** (rare upstream churn)
2. **ghostty** (most frequent upstream churn — usually 1-3 commits/week)
3. **herdr** (independent clone — no submodule pointer to bump)
4. **cmux** (parent — pins ghostty + bonsplit, depends on herdr binary at build time)

## Step-by-step sync

### 0. Pre-flight

```bash
cd /Users/wowdd1/Dev/cmux
git fetch upstream main && git fetch origin main
# Note divergence:
git log --oneline upstream/main ^main | head           # commits to pull
git log --oneline main ^upstream/main | head           # fork-only commits
```

### 1. bonsplit submodule

```bash
cd /Users/wowdd1/Dev/cmux/vendor/bonsplit
git fetch upstream main
git checkout main
git merge upstream/main --no-edit                      # resolve conflicts if any
git push origin main
```

If conflicts: prefer fork's commits when they touch fork-only features (e.g. `bcce62c fix(drag): write splitState`); take upstream when files are otherwise unchanged on fork side.

### 2. ghostty submodule

```bash
cd /Users/wowdd1/Dev/cmux/ghostty
git fetch upstream main
git checkout main
git merge upstream/main --no-edit
git push origin main
NEW_GHOSTTY_SHA=$(git rev-parse HEAD)
echo "$NEW_GHOSTTY_SHA"
```

After bumping ghostty, **trigger the GhosttyKit xcframework build** so cmux can download the prebuilt artifact instead of needing zig locally:

```bash
cd /Users/wowdd1/Dev/cmux
gh workflow run build-ghosttykit.yml --repo hhsw2015/cmux
# Wait ~15 min. Find the run, then:
gh run list --repo hhsw2015/cmux --workflow=build-ghosttykit.yml --limit 1 --json databaseId,status,conclusion
```

Workflow publishes to `https://github.com/hhsw2015/ghostty/releases/tag/xcframework-<SHA>-crashsubdir-cmux-crash-v1` and uses macos-15 runner (queued — may take hours during congestion, but it's a one-time bottleneck per ghostty bump).

Get the sha256 from the run logs:
```bash
gh run view <RUN_ID> --repo hhsw2015/cmux --log | grep "sha256 ="
```

Pin in `scripts/ghosttykit-checksums.txt`:
```
<NEW_GHOSTTY_SHA> <sha256>
```

### 3. herdr (separate clone)

```bash
cd /Users/wowdd1/Dev/herdr
git fetch upstream master
git checkout master
git merge upstream/master --no-edit
git push origin master
```

Common post-merge fixes:
- Duplicate enum/match arms (`WorkspaceRenamed`, etc.) — drop fork's copy when upstream adds the same name
- Field rename `request_client_sound_config_reload` → `request_client_config_reload` — keep upstream name
- `BufReader` import disappears after merge — re-add `use std::io::{BufRead, BufReader, ...}`
- `capabilities` moved in connection loop — `.clone()` it
- `raw_pty_tx` / `raw_pty_history` missing from the no-PTY `PaneRuntime` constructor — add them

After fix, push then **tag**:
```bash
# bump fork version in Cargo.toml + Cargo.lock to <upstream>-cmux<N+1>
# add CHANGELOG.md entry "## [<new-version>] - <date>"
git add Cargo.toml Cargo.lock CHANGELOG.md
git commit -m "release: vX.Y.Z-cmuxN"
git push origin master
git tag vX.Y.Z-cmuxN
git push origin vX.Y.Z-cmuxN
```

The `Release` workflow (.github/workflows/release.yml) is `v*` tag-triggered. It produces 4 platform binaries (linux x86_64/aarch64 musl, macos x86_64/arm64). cmux's bundle script picks them up by tag.

If release workflow fails on `error: section not found: <version>`, the CHANGELOG entry is missing — add it, retag, repush:
```bash
git tag -d vX.Y.Z-cmuxN
git push origin :refs/tags/vX.Y.Z-cmuxN
# fix CHANGELOG, commit, then retag + push
```

### 4. cmux parent merge

```bash
cd /Users/wowdd1/Dev/cmux
git checkout main
git merge upstream/main --no-edit
```

Submodule pointer conflicts:
- `ghostty` — keep your already-merged HEAD; `git update-index --cacheinfo 160000,$NEW_GHOSTTY_SHA,ghostty`
- `vendor/bonsplit` — same pattern

Source conflicts (recurring areas after most upstream merges):
| File | Common conflicts |
|---|---|
| `Sources/AppDelegate.swift` | `reopenMostRecentlyClosedItem` was inlined in fork, upstream split it into `AppDelegate+ClosedItemHistory.swift`. Drop the inline copy. |
| `Sources/TabManager.swift` | `FocusHistoryRecord(entry:)` wrapper, `ClosedItemHistoryStore` moved to its own file. Take upstream version + drop fork's inline definitions. |
| `Sources/Workspace.swift` | `restoreSessionSnapshot` now returns `[UUID: UUID]`. `clearCloseHistoryEligibility` helper introduced. Combine fork's herdr/zmx/scrollback fields with upstream's hibernation state. |
| `Sources/RestorableAgentSession.swift` | Fork has `snapshotsByPanel` / `snapshotsByPanelId`; upstream renamed to `entriesByPanel` / `entriesByPanelId` with `Entry` struct. Take upstream's structure, keep fork's claude-config-dir helper functions. |
| `Sources/ContentView.swift` | `HiddenTitlebarSidebarControlsView` gained `onFocusHistoryBack/Forward` callbacks. Both call sites must wire `tabManager.navigateBack/Forward` (with `NSSound.beep()` fallback). |
| `Sources/cmuxApp.swift` | `historyCommands` moved to `cmuxApp+HistoryMenu.swift`. Drop fork's inline copy. |
| `Sources/SessionPersistence.swift` | Combine fork's `zmx` field with upstream's `hibernation` field on `SessionTerminalPanelSnapshot`. |
| `cmux.xcodeproj/project.pbxproj` | Three places: `PBXBuildFile`, `PBXFileReference`, `Sources` build phase. Concatenate fork-only and upstream-only entries (no real conflict — `<<<<<<<` on contiguous added lines). |
| `Resources/Localizable.xcstrings` | New translation keys. Take upstream every time. |
| `docs/ghostty-fork.md` | Take upstream's newer version (more recent fork-head SHA + xcframework tag). |
| `web/data/cmux-shortcuts.ts` | Trivial label changes. Take upstream. |

After resolution:
```bash
git add -A
git commit --no-edit
git push origin main
```

## Build

**Prefer GitHub Actions when available; fall back to local only if the macOS runner pool is stuck.**

### Path A — GitHub Actions (preferred)

```bash
gh workflow run build.yml --repo hhsw2015/cmux
gh run list --repo hhsw2015/cmux --workflow=build.yml --limit 1
```

If the run picks up a runner within ~10 min, let it complete and download the artifact. If it stays queued for >30 min, cancel and fall back to Path B.

```bash
# Once green, grab the artifact:
gh run download <RUN_ID> --repo hhsw2015/cmux --name cmux-arm64
```

### Path B — Local (fallback)

```bash
cd /Users/wowdd1/Dev/cmux
./scripts/build-release-local.sh           # build only → /tmp/cmux-release-merge/Build/Products/Release/cmux.app
./scripts/build-release-local.sh --install  # build + replace /Applications/cmux.app + re-sign + clear quarantine
```

Behind the scenes:
- `CMUX_GHOSTTYKIT_REPO=hhsw2015/ghostty` — pull xcframework from fork release (avoids local zig build)
- `CMUX_SKIP_ZIG_BUILD=1` — skip the in-app Ghostty CLI helper zig build phase
- `xcodebuild -configuration Release -derivedDataPath /tmp/cmux-release-merge`
- `codesign --force --deep --sign -` — adhoc re-sign (Gatekeeper rejects the original adhoc once quarantine is added otherwise)

If install fails with `Code Signature Invalid` SIGKILL, run manually:
```bash
sudo xattr -cr /Applications/cmux.app
sudo codesign --force --deep --sign - /Applications/cmux.app
```

## Pre-release on hhsw2015/cmux

**Same priority: GitHub Actions release workflow first; manual upload as fallback.**

### Path A — workflow (preferred, when macOS runners free)

```bash
git tag "v0.64.10-$(git rev-parse --short=7 HEAD)"
git push origin "v0.64.10-$(git rev-parse --short=7 HEAD)"
# release.yml is `v*`-tag-triggered → builds, signs (if Apple secrets set), notarizes, uploads .dmg
gh run watch --repo hhsw2015/cmux
```

### Path B — manual upload (current fallback)


```bash
SHA=$(git rev-parse --short=7 HEAD)
TAG="v0.64.10-$SHA"   # match upstream's MARKETING_VERSION; bump if upstream did

# zip the .app
cd /tmp/cmux-release-merge/Build/Products/Release
zip -qry /tmp/cmux-arm64.zip cmux.app
ls -lah /tmp/cmux-arm64.zip   # ~55 MB compressed

cd /Users/wowdd1/Dev/cmux
git tag "$TAG"
git push origin "$TAG"

gh release create "$TAG" /tmp/cmux-arm64.zip \
  --repo hhsw2015/cmux \
  --prerelease \
  --title "cmux 0.64.10 ($SHA, arm64)" \
  --notes "Unsigned arm64 build from \`$(git rev-parse HEAD)\`.

Includes upstream cmux/main merge + ghostty fork bump + cmux-tmux backend.

Remove quarantine after download:
\`\`\`
xattr -cr /Applications/cmux.app
codesign --force --deep --sign - /Applications/cmux.app
\`\`\`
"
```

## Post-merge verification

After every upstream sync, run these in order. Stop at the first failure.

### 1. Automated guards (~30s)

```bash
./scripts/test-fork-regression.sh
```

Expected: `Executed 9 tests, with 0 failures`. Fails mean upstream changed
something that fork code depends on. See test names — each one names the
specific feature it guards.

If a test fails, read its failure message — it usually points at the
exact merge resolution that lost a fork-only behavior.

### 2. Manual test checklist (only after big upstream merges or any PR
that touches Workspace.swift / TabManager.swift / TerminalController.swift /
HerdrClient/* — particularly PR #4829 top tabs when it lands)

Build via `./scripts/build-release-local.sh --install`, then:

**zmx restore:**
- [ ] Open a panel running `zmx attach foo` against a real zmx daemon
- [ ] Quit cmux (Cmd-Q)
- [ ] Relaunch cmux
- [ ] Panel auto-reattaches to `foo` — terminal shows existing zmx state, not a fresh shell

**herdr backend:**
- [ ] Add a remote computer in Settings → Computers (SSH herdr flavor)
- [ ] Open a workspace on that computer, create 2 panels
- [ ] Quit cmux, relaunch
- [ ] Workspace reconnects, both panels alive, scrollback intact
- [ ] Close one panel — remote daemon still has the other (verify via `ssh host herdr-cmux list`)

**cmux-tmux backend:**
- [ ] Add a Local tmux computer in Settings → Computers (Local tmux flavor)
- [ ] Open a workspace, create 2 panels with different shell commands
- [ ] In a separate tmux client (`tmux ls`, `tmux attach`), confirm cmux's panes appear as tmux panes
- [ ] Quit cmux, relaunch — workspace + panes reattach to the running tmux session

**Top tabs (only after PR #4829 lands):**
- [ ] Cmd+T creates new top tab inside same workspace
- [ ] Each top tab has its own split tree (split in Tab1 doesn't show in Tab2)
- [ ] Ctrl+Tab / Ctrl+Shift+Tab cycle through top tabs
- [ ] herdr workspace + 2 top tabs: each tab's panes appear independently in herdr's `pane.list`
- [ ] cmux-tmux workspace + 2 top tabs: each tab maps to a distinct tmux window (`tmux list-windows`)
- [ ] Close one top tab → remote daemon retains the other tab's session

If any manual check fails, do NOT release. Open an issue tagged `fork-regression`, capture the broken behavior with the affected backend (zmx / herdr / cmux-tmux) in the title.

## Caveats

- **adhoc signing only** — downloaders need to run `xattr -cr` + `codesign --force --deep --sign -`. Public release would need Apple Developer cert + notarization (out of scope for this fork).
- **arm64 only** — `xcodebuild` builds for the host arch. For x86_64 add `-destination 'platform=macOS,arch=x86_64'`.
- **GitHub macOS runners** — Build app / Build GhosttyKit workflows run on `depot-macos-latest` or `macos-15`. During pool congestion they can queue for hours. Local builds bypass this.
- **No notarization** — first-run will trigger Gatekeeper unless quarantine is cleared.
- **cmux-tmux** is a separate Rust binary published via `cmux-tmux-v*` tags. Bump independently when its source changes; the cmux Xcode build phase bundles whatever release is current.
- **CMUX_TAG / scripts/cmux-debug-cli.sh** — for tagged dogfood Debug builds, never use the untagged debug socket. See main `CLAUDE.md` for the helper.

## Reference: env vars

| Var | Purpose |
|---|---|
| `CMUX_GHOSTTYKIT_REPO` | GitHub repo to fetch prebuilt xcframework from. Defaults to `manaflow-ai/ghostty`. Set to `hhsw2015/ghostty` when the upstream release doesn't exist for the current ghostty SHA. |
| `CMUX_SKIP_ZIG_BUILD` | Skip Xcode's in-target ghostty-cli-helper zig build. Required when zig isn't installed. |
| `CMUX_GHOSTTYKIT_NO_PREBUILT` | Force local zig build even if a prebuilt artifact exists. Not needed in normal sync flow. |
