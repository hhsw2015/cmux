import Bonsplit
import Foundation

/// Outbound bridge for pane zoom toggle. cmux's user-driven
/// `togglePaneZoom` fires `pane.set_zoom` to the daemon. The daemon
/// broadcasts `pane.zoomed` events back; the inbound apply path
/// (`HerdrInboundLayoutSync.applyZoom`) is idempotent — if cmux's
/// bonsplit already matches the desired state, the apply is a no-op,
/// so we don't need explicit echo suppression here. (The earlier
/// lastSent cache ABSORBED corrective broadcasts when the user
/// rapid-toggled, leaving cmux desynced from the daemon — fixed by
/// removing it and relying on idempotent apply.)
@MainActor
final class HerdrZoomSync {
    static let shared = HerdrZoomSync()

    private init() {}

    /// Called from Workspace after its bonsplit zoom toggles to fan
    /// the new state out to herdr. Bails when the cmux pane is not
    /// herdr-bound (regular cmux workspace, no remote to mirror).
    func reportLocalZoom(cmuxPaneId: UUID, zoomed: Bool) {
        guard let binding = HerdrTabRegistry.shared.binding(forCmuxPaneId: cmuxPaneId) else { return }
        guard let herdrPaneId = binding.paneBindings.herdrPaneId(forCmuxId: cmuxPaneId) else {
            return
        }
        let host = binding.host
        Task.detached { [host] in
            await HerdrOneShotRPC.send(
                host: host,
                method: "pane.set_zoom",
                params: ["pane_id": herdrPaneId, "zoomed": zoomed]
            )
        }
    }
}
