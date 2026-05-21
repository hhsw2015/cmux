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

    private struct LastSent: Equatable {
        let paneId: String
        let zoomed: Bool
    }

    private var lastSent: [UUID: LastSent] = [:]
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
        let snapshot = LastSent(paneId: herdrPaneId, zoomed: zoomed)
        if lastSent[host.id] == snapshot { return }
        lastSent[host.id] = snapshot
        Task.detached { [host] in
            await HerdrOneShotRPC.send(
                host: host,
                method: "pane.set_zoom",
                params: ["pane_id": herdrPaneId, "zoomed": zoomed]
            )
        }
    }

    func matchesLastSent(host: HerdrHost, herdrPaneId: String, zoomed: Bool) -> Bool {
        lastSent[host.id] == LastSent(paneId: herdrPaneId, zoomed: zoomed)
    }

    func beginApplyingRemote() { applyingRemote = true }
    func endApplyingRemote() { applyingRemote = false }
}
