import Bonsplit
import CmuxPanes
import CmuxSidebar
import CmuxTerminal
import CmuxWorkspaces
import Foundation

// Fork-only Workspace adapters that don't fit the top-tab machinery in
// Workspace+TopTabs.swift. Kept small.
@MainActor
extension Workspace {
    /// Stable per-workspace id, exposed for herdr callers that used to read
    /// `activeLayoutTab.id`. Points at the currently selected layout tab
    /// when set, falling back to the workspace id.
    var layoutTabId: UUID? {
        selectedLayoutTabId ?? id
    }

    /// Fork's HerdrClient calls this signature; forward to the real API and
    /// ignore `externalIo` (herdr wires I/O separately via
    /// `HerdrDisplayClient`).
    func newTerminalSurface(
        inPane paneId: PaneID,
        focus: Bool?,
        externalIo _: TerminalSurface.ExternalIoBinding
    ) -> TerminalPanel? {
        newTerminalSurface(inPane: paneId, focus: focus)
    }
}
