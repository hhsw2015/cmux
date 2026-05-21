import Bonsplit
import Foundation

/// Bidirectional bridge for pane zoom toggle. cmux's user-driven
/// `togglePaneZoom` fires `pane.set_zoom` to the daemon; the daemon's
/// broadcast `pane.zoomed` event mirrors back to cmux. Echo
/// suppression follows the HerdrFocusSync / HerdrWorkspaceFocusSync
/// pattern: lastSent caches the most recently emitted (paneId, zoomed)
/// per host, plus an applyingRemote flag brackets inbound writes so
/// the outbound hook is a no-op while we're materializing a remote
/// event.
@MainActor
final class HerdrZoomSync {
    static let shared = HerdrZoomSync()

    private struct PaneKey: Hashable {
        let hostId: UUID
        let herdrPaneId: String
    }

    /// Per-pane last-sent zoom flag. Earlier code keyed by host alone
    /// which collapsed concurrent zooms across different cmux
    /// workspaces sharing one host: a fast toggle on paneA followed
    /// by paneB would overwrite paneA's lastSent, and the daemon's
    /// broadcast for paneA's zoom would then mismatch and re-apply
    /// (echo loop).
    private var lastSent: [PaneKey: Bool] = [:]
    private(set) var applyingRemote: Bool = false

    private init() {}

    /// Called from Workspace after its bonsplit zoom toggles to fan
    /// the new state out to herdr. Looks up the host + herdr pane id
    /// for the cmux pane that just zoomed (or the previously-zoomed
    /// one when clearing).
    func reportLocalZoom(
        cmuxPaneId: UUID,
        zoomed: Bool
    ) {
        guard !applyingRemote else { return }
        guard let binding = HerdrTabRegistry.shared.binding(forCmuxPaneId: cmuxPaneId) else { return }
        guard let herdrPaneId = binding.paneBindings.herdrPaneId(forCmuxId: cmuxPaneId) else {
            return
        }
        let host = binding.host
        let key = PaneKey(hostId: host.id, herdrPaneId: herdrPaneId)
        if lastSent[key] == zoomed { return }
        lastSent[key] = zoomed
        Task.detached { [host] in
            await HerdrOneShotRPC.send(
                host: host,
                method: "pane.set_zoom",
                params: ["pane_id": herdrPaneId, "zoomed": zoomed]
            )
        }
    }

    func matchesLastSent(host: HerdrHost, herdrPaneId: String, zoomed: Bool) -> Bool {
        lastSent[PaneKey(hostId: host.id, herdrPaneId: herdrPaneId)] == zoomed
    }

    func beginApplyingRemote() { applyingRemote = true }
    func endApplyingRemote() { applyingRemote = false }
}
