import Foundation

/// Unified record for an agent process running in a panel. Merges info from
/// cmux's existing agent hook (Claude/Codex/Cursor) with whatever the
/// session daemon reports (tsm's `claude-statusline` sidecar). Each entry
/// tracks its sources so the UI can show "(cmux+tsm)" or single-source
/// without duplicating rows.
public struct CombinedAgentEntry: Sendable, Equatable, Identifiable {
    public let panelId: UUID
    public var sessionName: String?
    public var kind: AgentKind
    public var status: AgentStatus
    public var sources: Set<AgentSource>
    public var lastUpdate: Date

    public var id: UUID { panelId }

    public enum AgentKind: String, Sendable, Codable {
        case claude
        case codex
        case cursor
        case unknown
    }

    public enum AgentStatus: String, Sendable, Codable {
        case running
        case waiting    // waiting on user input
        case completed
        case error
    }

    public enum AgentSource: String, Sendable, Codable {
        case cmuxHook        // cmux's own agent-launch hook tracker
        case tsmEvent        // event from the daemon (tsm sidecar etc.)
    }

    public init(
        panelId: UUID,
        sessionName: String? = nil,
        kind: AgentKind,
        status: AgentStatus,
        sources: Set<AgentSource>,
        lastUpdate: Date = .init()
    ) {
        self.panelId = panelId
        self.sessionName = sessionName
        self.kind = kind
        self.status = status
        self.sources = sources
        self.lastUpdate = lastUpdate
    }
}

/// Reducer that merges per-source updates into a single entry per panel.
/// Newest update wins on conflict; sources accumulate so the UI can show
/// where the data came from.
public struct CombinedAgentReducer: Sendable {
    public init() {}

    public func merge(
        existing: CombinedAgentEntry?,
        update: CombinedAgentEntry
    ) -> CombinedAgentEntry {
        guard let existing else { return update }
        if update.lastUpdate > existing.lastUpdate {
            var merged = update
            merged.sources = existing.sources.union(update.sources)
            // Preserve session name when the new update doesn't carry one.
            if merged.sessionName == nil {
                merged.sessionName = existing.sessionName
            }
            return merged
        }
        var merged = existing
        merged.sources = existing.sources.union(update.sources)
        if merged.sessionName == nil {
            merged.sessionName = update.sessionName
        }
        return merged
    }

    public func remove(
        existing: CombinedAgentEntry?,
        source: CombinedAgentEntry.AgentSource
    ) -> CombinedAgentEntry? {
        guard var entry = existing else { return nil }
        entry.sources.remove(source)
        return entry.sources.isEmpty ? nil : entry
    }
}
