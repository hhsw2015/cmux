import CMUXSessionDaemon
import Foundation

/// Phase 7 wiring stub. Receives `CombinedAgentEntry` updates from the
/// (future) tsm sidecar watcher and the cmux agent hook tracker, runs them
/// through `CombinedAgentReducer`, and republishes the merged map.
///
/// Wiring into cmux's existing FeedCoordinator store happens through a
/// follow-up PR that updates the feed schema. For now this bridge is a
/// passive sink: callers can post updates and observe `entries`, but the
/// cmux feed UI does not yet read this map.
@MainActor
final class CombinedAgentFeedBridge: ObservableObject {
    static let shared = CombinedAgentFeedBridge()

    @Published private(set) var entries: [UUID: CombinedAgentEntry] = [:]

    private let reducer = CombinedAgentReducer()

    func ingest(update: CombinedAgentEntry) {
        let merged = reducer.merge(existing: entries[update.panelId], update: update)
        entries[update.panelId] = merged
#if DEBUG
        SessionPersistenceLog.event(
            "agent.merge",
            "panel=\(update.panelId.uuidString.prefix(8)) " +
            "kind=\(merged.kind.rawValue) status=\(merged.status.rawValue) " +
            "sources=\(merged.sources.map(\.rawValue).sorted().joined(separator: ","))"
        )
#endif
    }

    func dropSource(panelId: UUID, source: CombinedAgentEntry.AgentSource) {
        if let entry = reducer.remove(existing: entries[panelId], source: source) {
            entries[panelId] = entry
        } else {
            entries.removeValue(forKey: panelId)
        }
    }

    func clear(panelId: UUID) {
        entries.removeValue(forKey: panelId)
    }
}
