import CmuxPanes
import CmuxTerminal
import CmuxWorkspaces
import CmuxSidebar
import Bonsplit
import Foundation

// ponytail: fork-only Workspace stubs required by HerdrClient / fork extensions
@MainActor
extension Workspace {
    func isDeadHerdrStub() -> Bool { false }
    func markAllTabsForceCloseable() {}
    func bonsplitController(containingPaneId: PaneID) -> BonsplitController? { nil }
    func bonsplitController(forLayoutTabId: UUID) -> BonsplitController? { nil }
    var layoutTabId: UUID? { nil }
    func layoutTabId(containingPaneId paneId: PaneID) -> UUID? { nil }
    func herdrInboundSplit(direction: Any, panelId: UUID, source: String) {}
    func herdrInboundSplit(paneId: PaneID, orientation: Any, initialDividerPosition: CGFloat) -> PaneID? { nil }
    func sidebarStatusEntriesVisibleForDisplay() -> [SidebarStatusEntry] { [] }
    // ponytail: allowsAgentContinuation/restoredAgentSnapshotForContinuation/reconcileCompletedRestoredAgent now in Workspace+AgentLifecycle.swift
    func selectNextTopLevelTab() {}
    func selectPreviousTopLevelTab() {}
    func newTopLevelTerminalTab(focus: Bool = false, initialInput: String? = nil) {}
    // ponytail: setCustomDescription/applyProcessTitle now in Workspace.swift
    // Fork's HerdrClient calls this signature; forward to real API ignoring externalIo.
    func newTerminalSurface(inPane paneId: PaneID, focus: Bool?, externalIo: TerminalSurface.ExternalIoBinding) -> TerminalPanel? {
        newTerminalSurface(inPane: paneId, focus: focus)
    }
}
