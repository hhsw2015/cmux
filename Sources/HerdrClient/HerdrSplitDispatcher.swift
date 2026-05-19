import Bonsplit
import Foundation

/// Dispatches a `pane.split` RPC to herdr after the user splits a
/// herdr-backed pane locally in cmux. Called from
/// `Workspace.splitTabBar(_:didSplitPane:)` when `pendingHerdrSplit`
/// matched the originating pane. Cmux's auto-create of a local
/// terminal in `newPane` is suppressed by the caller, so this
/// dispatcher owns populating the new pane with a herdr-backed
/// terminal once the daemon returns the new pane id + terminal id.
@MainActor
enum HerdrSplitDispatcher {
    static func dispatch(
        workspace: Workspace,
        originalPane: PaneID,
        newPane: PaneID,
        orientation: SplitOrientation
    ) {
        guard let binding = HerdrTabRegistry.shared.binding(forCmuxPaneId: originalPane.id) else {
            return
        }
        guard let originalHerdrPaneId = binding.paneBindings.herdrPaneId(forCmuxId: originalPane.id) else {
            return
        }
        let host = binding.host
        guard let exec = HerdrLocalBinary.resolve() else { return }
        let socketPath = host.localApiSocketPath
        // Bonsplit's horizontal = side-by-side (new pane on right);
        // herdr's SplitDirection::Right places the new pane on the
        // right of the target. Vertical → Down.
        let direction = orientation == .horizontal ? "right" : "down"

        Task { @MainActor in
            do {
                let api = HerdrApiClient(transport: LocalUDSTransport(socketPath: socketPath))
                try await api.start()
                defer { Task { await api.close() } }
                let response = try await api.request(
                    method: "pane.split",
                    params: [
                        "target_pane_id": originalHerdrPaneId,
                        "direction": direction,
                        "focus": true,
                    ]
                )
                guard let pane = response["pane"] as? [String: Any],
                      let newHerdrPaneId = pane["pane_id"] as? String,
                      let newTerminalId = pane["terminal_id"] as? String
                else {
                    cmuxDebugLog("herdr.split: response missing pane info")
                    return
                }
                binding.paneBindings.bind(cmuxPaneId: newPane.id, herdrPaneId: newHerdrPaneId)
                _ = try await HerdrPanelOpener.wireHerdrBackedPanel(
                    workspace: workspace,
                    cmuxPaneId: newPane,
                    host: host,
                    terminalId: newTerminalId,
                    herdrPaneId: newHerdrPaneId,
                    executablePath: exec,
                    socketPath: socketPath,
                    focus: true
                )
                // Re-prime the divider lastSeen so the geometry
                // notification that fires when the new pane lands
                // doesn't echo back as a user-driven ratio change.
                HerdrDividerSync.prime(
                    binding: binding,
                    treeSnapshot: workspace.bonsplitController.treeSnapshot()
                )
            } catch {
                cmuxDebugLog("herdr.split: dispatch failed: \(error)")
            }
        }
    }
}
