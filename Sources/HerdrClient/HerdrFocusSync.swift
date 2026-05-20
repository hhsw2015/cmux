import Bonsplit
import Foundation

/// Outbound bridge for pane focus changes. Anchors at
/// `Workspace.splitTabBar(_:didFocusPane:)` so every focus path —
/// click, keyboard nav, programmatic — funnels through one place.
///
/// Coalesced: rapid focus flips (e.g. while the user clicks across
/// multiple panes in a second) collapse to a single trailing RPC so
/// we don't flood the daemon.
@MainActor
final class HerdrFocusSync {
    static let shared = HerdrFocusSync()

    /// Per-host last-sent pane id. Skips outbound when nothing changed
    /// (focus was already on this pane on the daemon's side).
    private var lastSent: [UUID: String] = [:]

    /// In-flight debounce task per host. New events cancel and replace.
    private var pending: [UUID: Task<Void, Never>] = [:]

    private init() {}

    func reportLocalFocus(cmuxPaneId: UUID) {
        guard let binding = HerdrTabRegistry.shared.binding(forCmuxPaneId: cmuxPaneId) else {
            return
        }
        guard let herdrPaneId = binding.paneBindings.herdrPaneId(forCmuxId: cmuxPaneId) else {
            return
        }
        let hostId = binding.host.id
        if lastSent[hostId] == herdrPaneId { return }
        // Cancel previous pending dispatch — the latest focus wins.
        pending[hostId]?.cancel()
        let task = Task { [host = binding.host] in
            // Coalesce rapid clicks. 60 ms is fast enough that the
            // user can't notice a delay but slow enough to drop most
            // intermediate flips during a multi-pane click sequence.
            try? await Task.sleep(nanoseconds: 60_000_000)
            if Task.isCancelled { return }
            await HerdrOneShotRPC.send(
                host: host,
                method: "pane.focus",
                params: ["pane_id": herdrPaneId]
            )
        }
        pending[hostId] = task
        lastSent[hostId] = herdrPaneId
    }

    /// Apply an inbound `pane.focused` event so cmux's focus follows
    /// what another client did. Skips if the local focus already
    /// matches (re-entrance guard against echoes of our own
    /// outbound).
    func applyRemoteFocus(host: HerdrHost, herdrPaneId: String) {
        if lastSent[host.id] == herdrPaneId { return }
        lastSent[host.id] = herdrPaneId
        // Walk every binding on this host and ask its pane mapping if
        // it owns the herdr pane id we just heard about. The cmux
        // PaneID lives inside that mapping.
        for binding in HerdrTabRegistry.shared.allBindings
        where binding.host.id == host.id {
            if let cmuxPaneId = binding.paneBindings.cmuxPaneId(forHerdrId: herdrPaneId) {
                guard let workspace = binding.workspace else { return }
                let target = PaneID(id: cmuxPaneId)
                workspace.bonsplitController.focusPane(target)
                return
            }
        }
    }
}
