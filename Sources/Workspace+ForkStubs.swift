import CmuxPanes
import CmuxTerminal
import CmuxWorkspaces
import CmuxSidebar
import Bonsplit
import Foundation

// Fork-only Workspace adapters. Upstream removed the layoutTabs / topTabController
// concept; each Workspace now has exactly one BonsplitController. These bridges
// let fork HerdrClient code keep its multi-layout API shape while operating on
// the single-layout upstream reality.
@MainActor
extension Workspace {
    /// Herdr stale-workspace detector. Upstream lacks the concept, so nothing is
    /// ever considered a dead-herdr stub on the current architecture.
    func isDeadHerdrStub() -> Bool { false }

    /// No-op adapter: upstream tabs are always closable; the fork flag lived on
    /// layoutTabs which no longer exist.
    func markAllTabsForceCloseable() {}

    /// One bonsplit per workspace. Return it iff the pane belongs to us.
    func bonsplitController(containingPaneId paneId: PaneID) -> BonsplitController? {
        bonsplitController.allPaneIds.contains(paneId) ? bonsplitController : nil
    }

    /// Layout tabs are gone. The single bonsplit answers for every layout id
    /// (herdr callers just need a controller to route mutations into).
    func bonsplitController(forLayoutTabId _: UUID) -> BonsplitController? {
        bonsplitController
    }

    /// Stable per-workspace id used as the sole layout id in single-layout mode.
    var layoutTabId: UUID? { id }

    /// Every owned pane belongs to the workspace's single layout id.
    func layoutTabId(containingPaneId paneId: PaneID) -> UUID? {
        bonsplitController.allPaneIds.contains(paneId) ? id : nil
    }

    /// Herdr inbound split (typed variant). Marks the split as programmatic so
    /// bonsplit doesn't fire an outbound RPC in response, then routes through
    /// the single bonsplit controller.
    @discardableResult
    func herdrInboundSplit(
        paneId: PaneID,
        orientation: SplitOrientation,
        initialDividerPosition: CGFloat
    ) -> PaneID? {
        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        return bonsplitController.splitPane(
            paneId,
            orientation: orientation,
            withTab: nil,
            initialDividerPosition: initialDividerPosition
        )
    }

    /// Herdr inbound split (loose variant kept for older callers passing a
    /// direction enum and panel id). Resolves the pane from the panel and
    /// delegates to the typed variant.
    func herdrInboundSplit(direction: SplitOrientation, panelId: UUID, source _: String) {
        guard let paneId = paneId(forPanelId: panelId) else { return }
        _ = herdrInboundSplit(paneId: paneId, orientation: direction, initialDividerPosition: 0.5)
    }

    // Cmd+T / next / previous top tab. Upstream collapsed top tabs into the
    // single bonsplit, so map fork's "new top tab" to "new terminal surface in
    // the focused pane" and the nav shortcuts to bonsplit's tab cycling within
    // the focused pane.
    func selectNextTopLevelTab() {
        guard let paneId = bonsplitController.focusedPaneId else { return }
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let current = bonsplitController.selectedTab(inPane: paneId),
              let idx = tabs.firstIndex(where: { $0.id == current.id }) else { return }
        let next = tabs[(idx + 1) % tabs.count]
        bonsplitController.selectTab(next.id)
    }

    func selectPreviousTopLevelTab() {
        guard let paneId = bonsplitController.focusedPaneId else { return }
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let current = bonsplitController.selectedTab(inPane: paneId),
              let idx = tabs.firstIndex(where: { $0.id == current.id }) else { return }
        let prev = tabs[(idx - 1 + tabs.count) % tabs.count]
        bonsplitController.selectTab(prev.id)
    }

    @discardableResult
    func newTopLevelTerminalTab(focus: Bool = true, initialInput: String? = nil) -> TerminalPanel? {
        newTerminalSurfaceInFocusedPane(focus: focus, initialInput: initialInput)
    }

    /// Fork's HerdrClient calls this signature; forward to real API ignoring
    /// externalIo (herdr wires I/O separately via HerdrDisplayClient).
    func newTerminalSurface(inPane paneId: PaneID, focus: Bool?, externalIo _: TerminalSurface.ExternalIoBinding) -> TerminalPanel? {
        newTerminalSurface(inPane: paneId, focus: focus)
    }
}
