import CoreGraphics
import Foundation

/// Pure-function layout math for the paper layout. Mirrors the Niri
/// algorithms in `scrolling.rs` (column placement, width resolution,
/// view-offset modes) but returns plain values so it can be unit-tested
/// without instantiating any SwiftUI views.
public enum PaperLayoutMath {
    /// Inter-column gap. PaperWM `window_gap` default is 8 px.
    public static let gap: CGFloat = 8

    /// Smallest column width we'll ever return after resolution +
    /// clamping. Floor protects against degenerate config + very
    /// narrow viewports.
    public static let minColumnWidth: CGFloat = 240

    /// Resolve a `PaperColumnWidth` to a concrete column width given
    /// the current viewport width. Subtracts gaps the way Niri's
    /// `Column::resolve_column_width` (`scrolling.rs:4401`) does.
    public static func resolveColumnWidth(_ width: PaperColumnWidth, viewportWidth: CGFloat) -> CGFloat {
        let usable = max(0, viewportWidth - 2 * gap)
        switch width {
        case let .proportion(p):
            let value = usable * CGFloat(p) - gap
            return max(minColumnWidth, value)
        case let .fixed(f):
            return max(minColumnWidth, f)
        case .fullWidth:
            return max(minColumnWidth, usable)
        }
    }

    /// Walk left-to-right, returning the X origin of each column.
    /// Mirror of Niri's `ScrollingSpace::column_xs`
    /// (`scrolling.rs:2304`). The first column starts at `gap`.
    public static func columnXs(
        columns: [PaperColumn],
        viewportWidth: CGFloat
    ) -> [CGFloat] {
        var xs: [CGFloat] = []
        xs.reserveCapacity(columns.count)
        var x: CGFloat = gap
        for col in columns {
            xs.append(x)
            x += resolveColumnWidth(col.width, viewportWidth: viewportWidth) + gap
        }
        return xs
    }

    /// Total width of the whole paper canvas — sum of column widths
    /// plus all the gaps. Used so the SwiftUI `LazyHStack` reports a
    /// stable content size.
    public static func canvasWidth(
        columns: [PaperColumn],
        viewportWidth: CGFloat
    ) -> CGFloat {
        guard !columns.isEmpty else { return 0 }
        var total: CGFloat = gap
        for col in columns {
            total += resolveColumnWidth(col.width, viewportWidth: viewportWidth) + gap
        }
        return total
    }

    /// Compute the absolute view origin (canvas-space X). Niri stores
    /// the view offset relative to the active column so changing
    /// active column doesn't have to manually adjust the offset.
    /// `viewOriginX = column_x(activeColumnIdx) + viewOffsetFromActiveColumn`.
    public static func viewOriginX(
        state: PaperLayoutState,
        viewportWidth: CGFloat
    ) -> CGFloat {
        guard !state.columns.isEmpty else { return 0 }
        let xs = columnXs(columns: state.columns, viewportWidth: viewportWidth)
        let activeX = xs[min(state.activeColumnIdx, xs.count - 1)]
        return activeX + state.viewOffsetFromActiveColumn
    }

    /// Given the focus mode, compute the `viewOffsetFromActiveColumn`
    /// that should be in effect for the active column. Mirrors Niri's
    /// `compute_new_view_offset_for_column` (`scrolling.rs:620`).
    public static func desiredViewOffsetFromActiveColumn(
        state: PaperLayoutState,
        viewportWidth: CGFloat
    ) -> CGFloat {
        guard let activeColumn = state.activeColumn else { return 0 }
        let columnW = resolveColumnWidth(activeColumn.width, viewportWidth: viewportWidth)
        switch state.focusMode {
        case .center:
            // Active column centered in the viewport. The offset is
            // relative to the active column's left edge, so subtract
            // half of the column width and a half-viewport.
            return -((viewportWidth - columnW) / 2)
        case .edge:
            // Snap left edge to viewport left, with a single gap.
            return -gap
        case .follow:
            // Niri's "fit" rule (`compute_new_view_offset` /
            // `scrolling.rs:5457`): if the column is wider than the
            // viewport, left-align (offset = 0 relative to it).
            // Otherwise compute a small symmetric padding and snap to
            // the closer edge to minimise motion. Stateless approxi-
            // mation: if it fits, leave a small symmetric padding.
            if columnW >= viewportWidth {
                return 0
            }
            let padding = max(0, min(gap, (viewportWidth - columnW) / 2))
            return -padding
        }
    }

    /// Apply the focus-mode rule, mutating the state.
    public static func snapToActiveColumn(
        _ state: inout PaperLayoutState,
        viewportWidth: CGFloat
    ) {
        state.viewOffsetFromActiveColumn = desiredViewOffsetFromActiveColumn(
            state: state,
            viewportWidth: viewportWidth
        )
    }
}

// MARK: - Tile heights

public extension PaperLayoutMath {
    /// Distribute a column's vertical space across its tiles.
    /// Niri's `Column::update_tile_sizes` (`scrolling.rs:4414`).
    /// Returns one CGFloat per tile, in `column.tiles` order.
    static func tileHeights(
        column: PaperColumn,
        availableHeight: CGFloat
    ) -> [CGFloat] {
        let tileCount = column.tiles.count
        guard tileCount > 0 else { return [] }
        let totalGap = gap * CGFloat(tileCount + 1)
        let usable = max(0, availableHeight - totalGap)

        var fixedTotal: CGFloat = 0
        var autoWeights: [(idx: Int, weight: Double)] = []
        for (i, tile) in column.tiles.enumerated() {
            switch tile.height {
            case let .fixed(h):
                fixedTotal += max(0, h)
            case let .auto(weight):
                autoWeights.append((i, max(0.0001, weight)))
            }
        }

        var heights = [CGFloat](repeating: 0, count: tileCount)
        var remaining = max(0, usable - fixedTotal)
        let totalWeight = autoWeights.reduce(0.0) { $0 + $1.weight }

        for tile in autoWeights {
            let share = totalWeight > 0
                ? remaining * CGFloat(tile.weight / totalWeight)
                : 0
            heights[tile.idx] = max(0, share)
        }
        for (i, tile) in column.tiles.enumerated() {
            if case let .fixed(h) = tile.height {
                heights[i] = max(0, h)
            }
        }
        return heights
    }
}
