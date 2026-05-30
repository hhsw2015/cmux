# Paper layout — design doc

## Goal

Add a Niri/PaperWM-style scrollable-tiling **paper layout** to cmux as an
opt-in workspace mode. Solve the "small laptop screen" problem: many panes
live on a wider-than-screen canvas; viewport scrolls horizontally; new
splits never shrink existing panes; users see multiple panes simultaneously
when they fit.

**Backwards compatible**: paper is a per-workspace mode flag. Default stays
bonsplit. All existing features (top tabs, layout tabs, herdr, sidebar,
persistence, shortcuts, settings) keep working unchanged. A workspace's
paper state is opt-in and stored in a nullable persistence field.

## Source projects

- **Niri** (`/tmp/paper-research/niri/src/layout/`) — Wayland scrollable
  compositor. Rust. Production-quality layout core (`scrolling.rs`,
  204k). Best reference for: data model, viewport math, animation policy,
  edge cases, swap/move/consume operations, preset widths.
- **PaperWM** (`/tmp/paper-research/PaperWM/`) — GNOME extension.
  JavaScript. Best reference for: drag-and-drop UX, trackpad gestures,
  three focus modes (DEFAULT/CENTER/EDGE), slurp/barf, take-window,
  minimap, position bar, focus-follows-momentum.

We borrow the **layout model from Niri** and the **interaction
vocabulary from PaperWM**. Neither project's code ports directly to
SwiftUI/AppKit; we re-implement the model in Swift on top of cmux's
existing Pane/Workspace types.

---

## 1. Mental model

A paper workspace is a **horizontal row of columns**. Each column holds a
**vertical stack of panes**. The viewport is window-sized; the row is
unbounded.

```
viewport (window)
┌────────────────────────────────────────────────┐
│  col 0    col 1     col 2     col 3            │   ← row scrolls left/right
│  ┌────┐  ┌────┐    ┌────┐    ┌────┐            │
│  │ p0 │  │ p1 │    │ p3 │    │ p5 │            │
│  ├────┤  │    │    └────┘    │    │            │
│  │ p? │  ├────┤              │    │            │
│  └────┘  │ p2 │              ├────┤            │
│          └────┘              │ p6 │            │
│                              └────┘            │
└────────────────────────────────────────────────┘
                                       ┊
                                       ┊  more columns off-screen →
```

Mapping to cmux:
- **Workspace** keeps its identity (sidebar entry, tabs, persistence row).
- A new mode `WorkspaceLayoutMode.paper` switches the workspace's content
  area between bonsplit (default) and paper. Toggling between modes is
  reversible and non-destructive.
- **Column** = ordered array of `(paneId, [tabId])`. Default = one pane,
  one tab. Vertical splits inside a column are added later (P2).
- **Tile/Pane** = a cmux `Panel` (existing type), rendered through
  `PanelContentView` (existing). No changes to terminal rendering.

---

## 2. Data model

```swift
public enum WorkspaceLayoutMode: String, Codable, Sendable {
    case bonsplit
    case paper
}

public enum PaperColumnWidth: Codable, Equatable, Sendable {
    /// Fraction of usable viewport width (after gaps).
    case proportion(Double)
    /// Absolute width in points.
    case fixed(CGFloat)
    /// "Maximize" — proportion 1.0 minus gaps.
    case fullWidth
}

public enum PaperTileHeight: Codable, Equatable, Sendable {
    case auto(weight: Double)   // most tiles; weighted share of remainder
    case fixed(CGFloat)         // explicit user-set height
}

public struct PaperTile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID         // pane id (matches cmux Panel.id)
    public var height: PaperTileHeight
}

public struct PaperColumn: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var tiles: [PaperTile]                  // non-empty
    public var activeTileIdx: Int                  // 0..<tiles.count
    public var width: PaperColumnWidth
    public var presetWidthIdx: Int?                // index into preset list, if cycling
    public var displayMode: PaperColumnDisplay     // .normal | .tabbed
}

public enum PaperColumnDisplay: String, Codable, Sendable {
    case normal
    case tabbed                                    // P3+
}

public enum PaperFocusMode: String, Codable, Sendable {
    case follow                                    // niri "fit" / paperwm DEFAULT
    case center                                    // both project's CENTER
    case edge                                      // paperwm EDGE
}

public struct PaperLayoutState: Codable, Equatable, Sendable {
    public var columns: [PaperColumn]              // non-empty when active
    public var activeColumnIdx: Int                // 0..<columns.count
    /// View offset relative to the active column's left edge.
    /// Niri's design: storing it relative makes "follow focus"
    /// arithmetic trivial.
    public var viewOffsetFromActiveColumn: CGFloat
    public var focusMode: PaperFocusMode
}
```

`Workspace` gains:

```swift
@Published var layoutMode: WorkspaceLayoutMode = .bonsplit
@Published var paperLayoutState: PaperLayoutState?
```

The PR 5014 cherry-pick already added these. We replace its
`PaperLayoutState`/`PaperPane` shape with the version above (PR's stores
absolute `frame` per pane; we move to "row of columns + cached widths"
matching Niri's model).

### Persistence

- New optional field on `SessionWorkspaceSnapshot`:
  `paperLayout: PaperLayoutSnapshot?`. Nil for bonsplit workspaces (the
  vast majority).
- `PaperLayoutSnapshot` mirrors `PaperLayoutState` but uses cmux pane
  ids; round-trips through Codable.
- Migration: schema version up. Old snapshots read `paperLayout = nil`,
  fall back to `bonsplit`. New persistence keeps both `bonsplit tree`
  AND `paperLayout` so toggling between modes survives quit/reopen.

---

## 3. Layout algorithm

Borrowed from Niri (`ScrollingSpace::column_xs`, `Column::resolve_column_width`).

### Column placement

Walk left-to-right:

```
x = gap
for col in columns:
    col.layoutX = x
    x += col.resolvedWidth + gap
```

`col.resolvedWidth`:
- `.proportion(p)`: `(viewport.w - 2*gap) * p - gap*innerGapAdjust`
- `.fixed(f)`: `f`
- `.fullWidth`: `viewport.w - 2*gap`

Clamped to per-column `[minWidth, maxWidth]` aggregated from each tile's
content min size (terminals report a small min, ~120pt; floor is the
window's `minWindowWidth`).

### Default new column width

Three preset cycle widths (PaperWM `cycle_width_steps`, Niri
`preset_column_widths`):

```
default presets = [.proportion(1.0/3), .proportion(0.5), .proportion(2.0/3)]
```

User-configurable in cmux Settings (P2). New columns start at preset
index 1 (= 0.5 viewport) by default — fits two columns side-by-side on a
typical laptop.

### Heights inside a column

Niri's algorithm (`Column::update_tile_sizes`):

1. Subtract per-tile fixed heights from available height.
2. Distribute remainder to `auto` tiles by their `weight`.
3. If a tile's content min exceeds its share, promote it to fixed and
   re-loop.

cmux uses this whenever `tabbed = false`. Tabbed mode (P3) gives every
tile the same height and only renders the active one.

### View position

`viewOriginX = column_x(activeColumnIdx) + viewOffsetFromActiveColumn`.

Per Niri: storing the offset relative to the active column means
"activate next column" is just `activeColumnIdx += 1` plus a snap on the
new column — the previous column's offset isn't needed.

---

## 4. Viewport scrolling

Three focus modes (PaperWM contract). On focus change or new column:

- **Follow** (default, niri's "fit"): if the focused column already fits
  fully inside the viewport, leave the offset alone. Otherwise nudge the
  smaller of (snap left edge with padding) vs (snap right edge with
  padding).
- **Center**: `viewOffset = -(viewport.w - col.w)/2`.
- **Edge**: snap the focused column's left edge to viewport left, with
  padding.

Implemented in `PaperLayoutState.computeViewOffsetForColumn(idx:)`.

### Animation

Use SwiftUI `withAnimation(.spring(response: 0.32, dampingFraction: 0.85))`
on `paperLayoutState` mutations. Match Niri's animation defaults.
Trigger an explicit `withTransaction(disableAnimations)` for the *first*
layout of an empty workspace and for persistence-restore.

### Trackpad / scrollwheel

Already prototyped in `PaperViewportScrollPannerView`. Replace the
direct `viewOffset += dx` with momentum (PaperWM `done()`):

- During pan: `viewOffset += dx` immediately, no animation.
- On `phase == .ended`: friction-decelerate with a Niri-style spring
  curve. Recompute the active column at the *projected target* (focus
  follows momentum) and snap to its preferred offset.

---

## 5. UI rendering

### Top-level structure

```
ZStack {
    PaperViewportScrollPanner       // background, catches scroll wheel
    GeometryReader { proxy in
        PaperCanvasView(state, viewport: proxy.size)
            .offset(x: -viewOriginX)
    }
}
```

### PaperCanvasView

```
HStack(spacing: gap) {
    ForEach(columns indexed) { col, idx in
        PaperColumnView(column: col, idx: idx, ...)
            .frame(width: col.resolvedWidth)
            .id(col.id)
    }
}
```

Use `LazyHStack` so off-viewport columns are not instantiated. Estimate
`width = sum(resolvedWidths)` so the HStack reports a stable size to the
scroller.

### PaperColumnView

```
VStack(spacing: gap) {
    ForEach(tiles indexed) { tile, idx in
        PanelContentView(panel: panel(for: tile))
            .frame(height: tile.resolvedHeight)
    }
}
```

PanelContentView is the existing cmux pane renderer. Reuse it
unchanged — tile.resolvedHeight is the only new external input.

### Off-viewport pane policy

- Columns whose layout rect doesn't intersect the viewport are not
  mounted (LazyHStack handles this).
- Columns whose rect intersects but pane is non-active *within the
  column* still render so the user sees them. The cmux portal terminal
  surface is already lazy-aware via `panelVisibleInUI`; reuse that to
  pause Metal updates for fully-occluded panes.

---

## 6. Operations (keyboard + menu + drag)

| Action                        | Default shortcut    | Source         |
|-------------------------------|---------------------|----------------|
| Toggle paper mode             | ⌃⌘P                | (us)           |
| Focus column left/right       | ⌃⌘← / ⌃⌘→         | PaperWM        |
| Focus tile up/down (in col)   | ⌃⌘↑ / ⌃⌘↓         | PaperWM        |
| New column right of focus     | ⌃⌘⇧↵               | PaperWM RIGHT  |
| New column left of focus      | ⌃⌘⌥↵               | PaperWM LEFT   |
| New tile in focused column    | ⌃⌘D                | PaperWM DOWN   |
| Move column left/right        | ⌃⌘⇧← / ⌃⌘⇧→       | PaperWM swap   |
| Move tile up/down in col      | ⌃⌘⇧↑ / ⌃⌘⇧↓       | PaperWM        |
| Cycle column width            | ⌃⌘R                | PaperWM        |
| Toggle column full width      | ⌃⌘F                | PaperWM        |
| Center focused column         | ⌃⌘C                | PaperWM        |
| Slurp (pull right column in)  | ⌃⌘I                | PaperWM        |
| Barf (push tile out as col)   | ⌃⌘O                | PaperWM        |
| Close active tile             | ⌘W (existing)       | cmux           |

Every shortcut goes through `KeyboardShortcutSettings` (per project
rules); each maps to a `WorkspacePaperAction.*` enum. Both the menu and
the cmux JSON config bind to this enum. Built into the Window menu, no
debug gate.

### Menu structure

```
Window menu
├─ Task Manager…
├─ Toggle Paper Layout         (⌃⌘P)
├─ Paper
│  ├─ Focus Column Left/Right
│  ├─ Focus Tile Up/Down
│  ├─ New Column Right/Left
│  ├─ New Tile Below
│  ├─ Move Column Left/Right
│  ├─ Move Tile Up/Down
│  ├─ Slurp / Barf
│  ├─ Cycle Column Width
│  ├─ Toggle Full Width
│  └─ Center Column
└─ …
```

---

## 7. Drag and drop (P3)

PaperWM's `MoveGrab` is the model. AppKit specifics:

- Drag handle = column header strip (top 16pt of column). Mouse-down
  there starts the drag; we re-parent the column view into a
  `NSWindow.contentView`-rooted floating actor so it can travel across
  workspaces.
- Drop zones (computed from layout):
  - Between columns: 100pt-wide strip on each column's left edge.
  - Inside a column: 250pt-tall strip per tile boundary.
  - After last column: synthetic "append" zone.
- Visual feedback: `tile-preview` analogue — a translucent rectangle
  that animates from 0→target size when the cursor enters a zone.
- Edge-drift while dragging: when cursor is within 12pt of the viewport
  edge, scroll the row at `drag_drift_speed`. Identical to PaperWM.

Cross-workspace drag is out of scope for P3. Re-parenting a column
across workspaces requires reasoning about herdr bindings (panes may
have herdr backing) and is a P4+ topic.

---

## 8. Gestures (P2)

- **Two/three-finger horizontal scroll**: pan the viewport (already
  prototyped). Add momentum + snap-to-column at end.
- **Pinch (two-finger)**: cycle column width (`Settings.prefs.cycle_width_steps`).
- **Workspace switcher gesture (four-finger horizontal)**: orthogonal
  feature (PaperWM-style workspace stack); **out of scope** for paper —
  cmux already has a workspace sidebar.

---

## 9. Performance

Three constraints:
1. **Typing latency**: focused pane must not regress.
2. **Many columns** (50+) without UI freeze.
3. **Off-viewport idleness**: hidden panes shouldn't burn CPU/GPU.

### Strategy

- **Mount**: LazyHStack only instantiates columns whose computed rect
  intersects the viewport (plus a small overscan). Off-viewport columns
  don't allocate `BonsplitController`/`PanelContentView`.
- **Render**: cmux's existing `panelVisibleInUI` flag pauses Metal
  draws for non-visible panes. Reuse: a paper tile is "visible in UI"
  iff its column is mounted AND it's the column's active tile (or the
  column is in normal display, in which case all visible tiles count).
- **Snapshot boundary**: per `CLAUDE.md` rule, `PaperColumnView` and
  `PaperTileView` MUST receive value snapshots, not the `Workspace`
  ObservableObject directly. This is the one expensive thing to get
  right; precedent is `IndexSectionActions` in `SessionIndexView.swift`.
- **Hit-testing**: keyboard focus only routes to the focused tile's
  surface. Hit-test path stays in `WindowTerminalHostView.hitTest()`
  (paper doesn't add work here).

### Numbers (estimate)

- 1 visible column with 1 tile: identical cost to bonsplit single pane.
- 4 visible columns × 1 tile each: 4 Metal layers active (focused-only
  rendering reduces to 1 active draw). Tested on M-series mac mini
  with 6+ Ghostty surfaces — fine.
- 50 columns: 4 mounted, 46 not in DOM. SwiftUI re-layout cost is the
  HStack stride sum (cheap, O(n) of cached widths).

---

## 10. Phases

### P0 — minimum viable (≈600 lines)

- Replace PR 5014's `PaperLayoutState`/`PaperPane` with the column
  model.
- `WorkspaceContentView` paper case renders a `LazyHStack` of columns
  at their resolved widths, offset by viewport origin.
- New tile = `barf` of single-pane column to a new column at right.
- Move column left/right (`⌃⌘⇧←/→`).
- Focus column left/right (`⌃⌘←/→`).
- Cycle column width (`⌃⌘R`).
- Trackpad scroll panner (already done) + snap-to-column on end.
- Persist `PaperLayoutState` in SessionPersistence (round-trip).
- Manual smoke test only; no unit tests yet.

### P1 — close + multi-tile column

- Close active tile (`⌘W`) — handle empty-column collapse, focus
  fallback (PaperWM `removeWindow` rules).
- Vertical split inside a column (`⌃⌘D`).
- Focus tile up/down within column.
- Move tile up/down within column.
- Height resize (`⌃⌘+/-` on tile).
- Slurp / barf (`⌃⌘I/O`).

### P2 — settings + gestures

- Settings UI (CmuxSettings catalog): focus mode, default column width
  preset, gap size, cycle steps, momentum on/off.
- Pinch to cycle column width.
- Trackpad momentum-decelerate scroll with focus snap.
- Position bar in titlebar (PaperWM affordance: shows where focused
  column sits in the row).
- Center focused column (`⌃⌘C`).
- Toggle full width (`⌃⌘F`).

### P3 — drag-and-drop + tabbed columns

- Column drag handle + drop zones + edge-drift auto-scroll.
- Tabbed display mode for a column (Niri's `ColumnDisplay::Tabbed`).
- Minimap overlay (PaperWM-style scrubbable strip).

### P4 — cross-workspace and beyond (later)

- Drag column across workspaces.
- "Take window" carry buffer.
- Orthogonal scratch layer.
- herdr remote awareness (paper layout for remote workspaces).

---

## 11. Risks + mitigations

| Risk                                              | Mitigation                                                                       |
|---------------------------------------------------|----------------------------------------------------------------------------------|
| `@Published` storms re-rendering whole row        | Snapshot boundary at `PaperColumnView`; rows hold value structs only             |
| Typing latency regression                         | Don't touch `WindowTerminalHostView.hitTest()` or `TerminalSurface.forceRefresh` |
| Persistence corruption                            | New nullable field; bonsplit tree always preserved as fallback                   |
| `Workspace.swift` already a god file (~18k lines) | Extract paper into `Sources/PaperLayout/` (new directory) — pure data + views    |
| Concurrent paper + bonsplit + herdr on same pane  | Mode flag is workspace-level; herdr binds per-pane and is mode-agnostic          |
| CLAUDE.md `@Observable` rule                      | New types use `@Observable`; migrate as new files are added                      |

### Rollback

If paper turns out unstable: set `WorkspaceLayoutMode.paper` unreachable
from the menu/shortcuts (one-line change), persistence reads back as
`.bonsplit`, paper code stays for next attempt. No data loss, no schema
break — the bonsplit tree is always persisted alongside.

---

## 12. Test strategy

- **Unit**: `PaperLayoutStateTests` covers column placement math,
  view-offset modes (follow/center/edge), insert-at-active-right,
  remove-with-focus-fallback, slurp/barf invariants. Pure value types,
  no SwiftUI.
- **Integration**: `WorkspacePaperLayoutTests` mounts a `Workspace`,
  toggles into paper, performs a sequence of operations, asserts the
  tile and column tree.
- **Persistence**: round-trip a `PaperLayoutSnapshot` through
  `SessionPersistencePolicy`; assert column ids and viewport offset
  survive.
- **Manual smoke**: dogfood checklist per phase.
- **No UI tests** for paper layout (UI test infra is XCUITest, slow,
  flaky for this kind of geometry-heavy work). Manual + unit + the
  golden-path `WorkspacePaperLayoutTests` are sufficient.

---

## 13. Open questions

1. Is paper a workspace mode (we recommend yes ✓) or a new workspace
   *type* (separate sidebar entry)? Workspace mode = less duplication.
2. Should `layoutTabs` be allowed in paper mode? Draft answer: no — paper
   mode hides the layout-tab strip; one paper canvas per workspace. Layout
   tabs are a bonsplit concept.
3. Should top tabs (Ghostty-style ribbon) survive in paper? Draft answer:
   no — paper columns *are* the navigation. Top tabs become redundant.
4. Default column-width preset: 1/2 viewport (recommend) or 1/3? PaperWM's
   default is `0.4`, Niri's is `0.5` for a 2-column split.
5. Rendering: do we want to render columns *outside* the viewport (with
   small overscan, e.g. 10% on each side) so trackpad swipe pre-warms,
   or strictly clip? Trade-off is "snappier scroll" vs "less RAM".
   Recommend overscan = 1 viewport's worth on each side (Niri's
   approach).

---

## 14. Action items

After review of this doc:
1. Confirm phase ordering (P0 → P3).
2. Lock in the open-question defaults (or override).
3. Start P0: replace PR 5014's `PaperLayoutState`/`PaperPane` with this
   document's column model. PR 5014's debug menu, trackpad panner, and
   keyboard shortcuts are reused as-is.
4. Each phase ships as a single commit + release build + manual smoke
   pass before moving to the next. No parallel phases.
5. Track progress in `docs/paper-layout-progress.md` (separate file)
   updated at the end of each phase.

---

## References

- Niri: https://github.com/YaLTeR/niri (`src/layout/scrolling.rs`,
  `src/layout/workspace.rs`, `src/layout/tile.rs`)
- PaperWM: https://github.com/paperwm/PaperWM (`tiling.js`,
  `grab.js`, `gestures.js`, `navigator.js`)
- PR 5014: https://github.com/manaflow-ai/cmux/pull/5014 (cherry-picked
  baseline, keeps existing `WorkspaceLayoutMode.paper` enum +
  `paperLayoutState` field but replaces the data shape)
