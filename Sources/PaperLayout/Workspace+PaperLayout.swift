import Bonsplit
import Foundation

/// Paper-layout operations on `Workspace`. Kept in its own extension
/// file so the god `Workspace.swift` doesn't grow further. All public
/// entry points the menu / shortcuts / keyboard route into for paper.
extension Workspace {
    // MARK: - Mode toggle

    /// Toggle this workspace between `bonsplit` and `paper` modes.
    /// The bonsplit tree is preserved when entering paper, so toggling
    /// back is non-destructive. Paper state is rebuilt from the
    /// current bonsplit panes on each entry.
    func togglePaperLayoutMode() {
        switch layoutMode {
        case .bonsplit:
            paperLayoutState = buildPaperStateFromBonsplit()
            layoutMode = .paper
        case .paper:
            layoutMode = .bonsplit
        }
    }

    /// Build a paper state seeded from the active layout-tab's
    /// bonsplit pane order. One column per existing pane, single tile
    /// per column. The currently focused pane (if any) becomes the
    /// active column.
    private func buildPaperStateFromBonsplit() -> PaperLayoutState? {
        let controller = bonsplitController
        let paneIds = controller.allPaneIds
        guard !paneIds.isEmpty else { return nil }

        // Resolve each Bonsplit PaneID → cmux Panel UUID via the
        // selected tab in that pane.
        let panelIds: [UUID] = paneIds.compactMap { paneId in
            guard let tabId = controller.selectedTab(inPane: paneId)?.id else { return nil }
            return panelIdFromSurfaceId(tabId)
        }
        guard !panelIds.isEmpty else { return nil }

        guard var state = PaperLayoutState.fromBonsplitPaneIds(panelIds) else { return nil }
        // Focus the column whose pane matches the workspace's current
        // focused panel, when possible.
        if let focused = focusedPanelId,
           let idx = state.columnIndex(containingPaneId: focused) {
            state.activeColumnIdx = idx
        }
        return state
    }

    // MARK: - Focus / move operations

    /// Move focus to the column at offset `delta` from the active one.
    /// `delta = -1` focuses the left neighbour; `+1` the right.
    func focusPaperColumn(delta: Int) {
        guard layoutMode == .paper else { return }
        guard var state = paperLayoutState else { return }
        let target = state.activeColumnIdx + delta
        guard state.columns.indices.contains(target) else { return }
        state.focusColumn(target)
        paperLayoutState = state

        // Sync the cmux-level focused panel so the rest of the app
        // (sidebar highlight, herdr binding, keyboard intent) stays
        // aligned. Use forceBonsplitFocusPath=true so this call
        // doesn't recursively re-enter the paper focus path.
        if let paneId = state.focusedPaneId {
            focusPanel(paneId, forceBonsplitFocusPath: true)
        }
    }

    /// Move the active column left or right within the row.
    func moveActivePaperColumn(delta: Int) {
        guard layoutMode == .paper else { return }
        guard var state = paperLayoutState else { return }
        switch delta.signum() {
        case -1: state.moveActiveColumnLeft()
        case 1: state.moveActiveColumnRight()
        default: return
        }
        paperLayoutState = state
    }

    /// Cycle the active column's width through the user's preset list.
    func cycleActivePaperColumnWidth(viewportWidth: CGFloat) {
        guard layoutMode == .paper else { return }
        guard var state = paperLayoutState else { return }
        state.cycleActiveColumnWidth(viewportWidth: viewportWidth)
        paperLayoutState = state
    }

    // MARK: - Trackpad / scroll-wheel viewport panning

    /// Pan the paper viewport. Called from the SwiftUI scroll panner.
    /// `dx > 0` reveals content to the right.
    func panPaperViewport(dx: CGFloat, dy: CGFloat) {
        guard layoutMode == .paper else { return }
        guard var state = paperLayoutState else { return }
        // Horizontal pan only for P0; vertical scrolling within a
        // tile flows through the pane's own scroll path.
        state.viewOffsetFromActiveColumn += dx
        paperLayoutState = state
    }

    // MARK: - Bonsplit -> paper mirror

    /// Mirror a bonsplit split into the paper canvas: the new pane
    /// becomes a fresh column inserted to the right of the source's
    /// column. Vertical splits inside one column are P1; for now both
    /// orientations land as a new column.
    func mirrorPaperSplit(sourcePaneId: UUID, newPaneId: UUID, orientation: SplitOrientation) {
        guard layoutMode == .paper else { return }
        var state = paperLayoutState ?? PaperLayoutState.initial(paneId: sourcePaneId)
        if let sourceCol = state.columnIndex(containingPaneId: sourcePaneId) {
            state.activeColumnIdx = sourceCol
        }
        state.insertColumnRightOfActive(paneId: newPaneId)
        paperLayoutState = state
    }

    /// Replacement for the legacy `focusPaperPanel(tabId:panelId:)`
    /// hook. Updates `activeColumnIdx` to the column containing
    /// `panelId` so the canvas snaps to the focused pane.
    func focusPaperPane(panelId: UUID) {
        guard layoutMode == .paper else { return }
        guard var state = paperLayoutState else { return }
        guard let idx = state.columnIndex(containingPaneId: panelId) else { return }
        state.focusColumn(idx)
        paperLayoutState = state
    }
}
