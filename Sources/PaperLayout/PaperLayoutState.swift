import CoreGraphics
import Foundation

/// Workspace layout mode. `bonsplit` is cmux's default tree-based layout;
/// `paper` is the Niri/PaperWM-style scrollable column layout.
public enum WorkspaceLayoutMode: String, Codable, Sendable {
    case bonsplit
    case paper
}

/// User-facing focus policy for the paper viewport. Mirrors PaperWM's
/// three modes (`tiling.js:37`).
public enum PaperFocusMode: String, Codable, Sendable {
    /// Only scroll when the focused column would otherwise clip the
    /// viewport. Default — feels least surprising.
    case follow
    /// Always center the focused column. Good for ultra-wide screens.
    case center
    /// Snap the focused column's edge to the viewport edge.
    case edge
}

/// How wide a column is. Resolved against the viewport width when
/// laying out (`PaperLayoutMath.resolveColumnWidth`).
public enum PaperColumnWidth: Codable, Equatable, Sendable {
    /// Fraction of the usable viewport width (after gaps).
    case proportion(Double)
    /// Absolute width in points.
    case fixed(CGFloat)
    /// 1.0 proportion — the column fills the whole usable viewport.
    case fullWidth
}

/// How tall a tile is within its column. Borrowed verbatim from Niri's
/// `WindowHeight` enum (`scrolling.rs:257`).
public enum PaperTileHeight: Codable, Equatable, Sendable {
    /// Most tiles use this. The remainder of the column's height is
    /// distributed proportionally to each `auto` tile's `weight`.
    case auto(weight: Double)
    /// Explicit user-set height. At most one non-auto tile per column.
    case fixed(CGFloat)

    public static let defaultAuto: PaperTileHeight = .auto(weight: 1.0)
}

/// One pane (= cmux `Panel`) inside a column.
public struct PaperTile: Codable, Identifiable, Equatable, Sendable {
    /// Matches the cmux `Panel.id` so renderers can resolve content.
    public var id: UUID
    public var height: PaperTileHeight

    public init(id: UUID, height: PaperTileHeight = .defaultAuto) {
        self.id = id
        self.height = height
    }
}

/// One column — a vertical stack of tiles. Columns are arrayed
/// horizontally on the paper canvas.
public struct PaperColumn: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var tiles: [PaperTile]
    public var activeTileIdx: Int
    public var width: PaperColumnWidth
    /// Index into the user's `presetWidths` array if the column was
    /// last sized by `cycleColumnWidth`. Niri stores it on `Column`
    /// (`scrolling.rs:163`) so the next cycle picks the right neighbour.
    public var presetWidthIdx: Int?

    public init(
        id: UUID = UUID(),
        tiles: [PaperTile],
        activeTileIdx: Int = 0,
        width: PaperColumnWidth = .proportion(0.5),
        presetWidthIdx: Int? = 1
    ) {
        precondition(!tiles.isEmpty, "PaperColumn must hold at least one tile")
        precondition(tiles.indices.contains(activeTileIdx), "activeTileIdx out of range")
        self.id = id
        self.tiles = tiles
        self.activeTileIdx = activeTileIdx
        self.width = width
        self.presetWidthIdx = presetWidthIdx
    }

    public var activeTile: PaperTile {
        tiles[activeTileIdx]
    }
}

/// The full paper layout for one workspace.
///
/// Storage shape borrowed from Niri (`ScrollingSpace`,
/// `scrolling.rs:34-95`): a row of columns plus the active column
/// index plus a *relative* view offset. Storing the offset relative
/// to the active column means activating a neighbour is just an
/// `activeColumnIdx ± 1` plus a snap — the previous column's offset
/// is irrelevant.
public struct PaperLayoutState: Codable, Equatable, Sendable {
    public var columns: [PaperColumn]
    public var activeColumnIdx: Int
    /// View offset relative to the active column's left edge. A value
    /// of 0 means the active column starts at the left of the viewport;
    /// negative values reveal whitespace / earlier columns to the left.
    public var viewOffsetFromActiveColumn: CGFloat
    public var focusMode: PaperFocusMode

    public init(
        columns: [PaperColumn],
        activeColumnIdx: Int = 0,
        viewOffsetFromActiveColumn: CGFloat = 0,
        focusMode: PaperFocusMode = .follow
    ) {
        precondition(!columns.isEmpty, "PaperLayoutState must hold at least one column")
        precondition(columns.indices.contains(activeColumnIdx), "activeColumnIdx out of range")
        self.columns = columns
        self.activeColumnIdx = activeColumnIdx
        self.viewOffsetFromActiveColumn = viewOffsetFromActiveColumn
        self.focusMode = focusMode
    }
}

// MARK: - Conveniences

public extension PaperLayoutState {
    /// True when there are no columns. Constructors enforce non-empty,
    /// but persistence-restore can produce a value with zero columns
    /// while the workspace is being repopulated.
    var isEmpty: Bool { columns.isEmpty }

    var activeColumn: PaperColumn? {
        guard columns.indices.contains(activeColumnIdx) else { return nil }
        return columns[activeColumnIdx]
    }

    /// The cmux pane id for the focused tile of the focused column,
    /// or nil if no columns / tiles exist.
    var focusedPaneId: UUID? {
        activeColumn?.activeTile.id
    }

    /// Column id at a given pane id (the pane the user clicked, etc).
    func columnIndex(containingPaneId paneId: UUID) -> Int? {
        columns.firstIndex { col in
            col.tiles.contains { $0.id == paneId }
        }
    }

    /// Tile index inside a column for a given pane id.
    func tileIndex(in column: PaperColumn, paneId: UUID) -> Int? {
        column.tiles.firstIndex { $0.id == paneId }
    }
}

// MARK: - Mutations

public extension PaperLayoutState {
    /// Build a paper state from a single seed pane — used when the
    /// workspace first enters paper mode and there is no prior state.
    static func initial(paneId: UUID) -> PaperLayoutState {
        PaperLayoutState(
            columns: [PaperColumn(tiles: [PaperTile(id: paneId)])],
            activeColumnIdx: 0,
            viewOffsetFromActiveColumn: 0,
            focusMode: .follow
        )
    }

    /// Build a paper state from a list of pane ids (one per column,
    /// in order). Used when toggling into paper from a bonsplit tree.
    static func fromBonsplitPaneIds(_ paneIds: [UUID]) -> PaperLayoutState? {
        guard !paneIds.isEmpty else { return nil }
        let columns = paneIds.map { PaperColumn(tiles: [PaperTile(id: $0)]) }
        return PaperLayoutState(columns: columns)
    }

    /// Move focus to the column at `idx`. Clamped.
    mutating func focusColumn(_ idx: Int) {
        let clamped = max(0, min(columns.count - 1, idx))
        activeColumnIdx = clamped
        // The relative-offset model means the new column's offset is
        // re-derived by the view layer (see PaperLayoutMath).
        viewOffsetFromActiveColumn = 0
    }

    /// Insert a new column to the right of the active one and focus it.
    mutating func insertColumnRightOfActive(paneId: UUID) {
        let column = PaperColumn(tiles: [PaperTile(id: paneId)])
        let insertAt = activeColumnIdx + 1
        columns.insert(column, at: min(insertAt, columns.count))
        activeColumnIdx = insertAt
        viewOffsetFromActiveColumn = 0
    }

    /// Insert a new column to the left of the active one and focus it.
    mutating func insertColumnLeftOfActive(paneId: UUID) {
        let column = PaperColumn(tiles: [PaperTile(id: paneId)])
        columns.insert(column, at: activeColumnIdx)
        // activeColumnIdx already points at the now-shifted-right
        // original column — bump it back so we focus the new one.
        // (No: we want focus on the new one which is at activeColumnIdx.)
        viewOffsetFromActiveColumn = 0
    }

    /// Swap the active column with its left neighbour.
    mutating func moveActiveColumnLeft() {
        guard activeColumnIdx > 0 else { return }
        columns.swapAt(activeColumnIdx, activeColumnIdx - 1)
        activeColumnIdx -= 1
        viewOffsetFromActiveColumn = 0
    }

    /// Swap the active column with its right neighbour.
    mutating func moveActiveColumnRight() {
        guard activeColumnIdx < columns.count - 1 else { return }
        columns.swapAt(activeColumnIdx, activeColumnIdx + 1)
        activeColumnIdx += 1
        viewOffsetFromActiveColumn = 0
    }

    /// Remove the column containing `paneId` (and any tiles it had).
    /// Returns the new active pane id, or nil if the workspace is now
    /// empty.
    @discardableResult
    mutating func removeColumn(containingPaneId paneId: UUID) -> UUID? {
        guard let columnIdx = columnIndex(containingPaneId: paneId) else {
            return focusedPaneId
        }
        columns.remove(at: columnIdx)
        if columns.isEmpty {
            activeColumnIdx = 0
            viewOffsetFromActiveColumn = 0
            return nil
        }
        // Niri's "previous-column-on-removal" rule: if the user just
        // opened this column and immediately closed it, focus snaps
        // back to the original column. We don't track that yet — fall
        // back to PaperWM's "focus the right neighbour" rule.
        if columnIdx <= activeColumnIdx {
            activeColumnIdx = max(0, activeColumnIdx - 1)
        }
        activeColumnIdx = min(activeColumnIdx, columns.count - 1)
        viewOffsetFromActiveColumn = 0
        return focusedPaneId
    }
}

// MARK: - Width cycling

/// User-configurable width presets the user cycles through with
/// ⌃⌘=. Default mimics PaperWM's `cycle_width_steps` (`settings.js`):
/// roughly thirds, halves, two-thirds.
public struct PaperWidthPresets: Codable, Equatable, Sendable {
    public var values: [PaperColumnWidth]

    public static let `default` = PaperWidthPresets(values: [
        .proportion(1.0 / 3.0),
        .proportion(0.5),
        .proportion(2.0 / 3.0),
    ])

    public init(values: [PaperColumnWidth]) {
        self.values = values
    }
}

public extension PaperLayoutState {
    /// Cycle the active column's width through `presets`. If the
    /// column isn't currently on a preset, jumps to the next preset
    /// strictly bigger than the current resolved width — same as
    /// Niri's `Column::toggle_width` (`scrolling.rs:4796`).
    mutating func cycleActiveColumnWidth(
        presets: PaperWidthPresets = .default,
        viewportWidth: CGFloat
    ) {
        guard activeColumnIdx < columns.count else { return }
        let presetCount = presets.values.count
        guard presetCount > 0 else { return }

        var col = columns[activeColumnIdx]
        let nextIdx: Int
        if let current = col.presetWidthIdx {
            nextIdx = (current + 1) % presetCount
        } else {
            // Pick the first preset strictly larger than the current
            // resolved width. Fall back to the smallest if nothing's
            // larger.
            let currentResolved = PaperLayoutMath.resolveColumnWidth(col.width, viewportWidth: viewportWidth)
            let larger = presets.values.firstIndex { preset in
                PaperLayoutMath.resolveColumnWidth(preset, viewportWidth: viewportWidth) > currentResolved + 1
            }
            nextIdx = larger ?? 0
        }
        col.width = presets.values[nextIdx]
        col.presetWidthIdx = nextIdx
        columns[activeColumnIdx] = col
    }
}
