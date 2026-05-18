import Foundation

/// One herdr workspace as it appears in cmux's sidebar.
struct HerdrWorkspaceSummary: Identifiable, Equatable, Hashable {
    let workspaceId: String
    let label: String
    let paneCount: Int
    let agentStatus: String?
    let activeTabId: String?

    var id: String { workspaceId }
}

/// Per-host cache of workspaces fetched via `workspace.list`. The
/// sidebar reads `workspaces(forHost:)`; consumers call
/// `refresh(host:)` to fetch (or re-fetch) and observe published
/// changes.
@MainActor
final class HerdrWorkspaceListStore: ObservableObject {
    static let shared = HerdrWorkspaceListStore()

    @Published private(set) var workspacesByHost: [UUID: [HerdrWorkspaceSummary]] = [:]
    @Published private(set) var lastErrorByHost: [UUID: String] = [:]
    @Published private(set) var inFlightHosts: Set<UUID> = []

    private init() {}

    func workspaces(forHost host: HerdrHost) -> [HerdrWorkspaceSummary] {
        workspacesByHost[host.id] ?? []
    }

    func isLoading(host: HerdrHost) -> Bool {
        inFlightHosts.contains(host.id)
    }

    /// Fetch (or re-fetch) the workspace list for `host`. Coalesces
    /// concurrent calls per host.
    func refresh(host: HerdrHost) {
        guard !inFlightHosts.contains(host.id) else { return }
        inFlightHosts.insert(host.id)
        let hostId = host.id
        Task { @MainActor in
            do {
                let summaries = try await Self.fetch(host: host)
                workspacesByHost[hostId] = summaries
                lastErrorByHost.removeValue(forKey: hostId)
            } catch {
                lastErrorByHost[hostId] = String(describing: error)
            }
            inFlightHosts.remove(hostId)
        }
    }

    /// Drop the cache for `host` so the next `refresh` re-fetches even
    /// if data was already cached. Used when an event tells us the
    /// list changed remotely.
    func invalidate(hostId: UUID) {
        workspacesByHost.removeValue(forKey: hostId)
    }

    private static func fetch(host: HerdrHost) async throws -> [HerdrWorkspaceSummary] {
        let api = HerdrApiClient(transport: HerdrTransportFactory.make(host: host))
        try await api.start()
        defer { Task { await api.close() } }

        let result = try await api.request(method: "workspace.list", params: [:])
        guard let workspaces = result["workspaces"] as? [[String: Any]] else {
            return []
        }

        return workspaces.compactMap { ws -> HerdrWorkspaceSummary? in
            guard let id = ws["workspace_id"] as? String else { return nil }
            let label = ws["label"] as? String ?? id
            let paneCount = ws["pane_count"] as? Int ?? 0
            let agentStatus = ws["agent_status"] as? String
            let activeTabId = ws["active_tab_id"] as? String
            return HerdrWorkspaceSummary(
                workspaceId: id,
                label: label,
                paneCount: paneCount,
                agentStatus: agentStatus,
                activeTabId: activeTabId
            )
        }
    }
}
