import Foundation
import UserNotifications

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
                detectAgentBlockedTransitions(host: host, newSummaries: summaries)
                workspacesByHost[hostId] = summaries
                lastErrorByHost.removeValue(forKey: hostId)
            } catch {
                lastErrorByHost[hostId] = String(describing: error)
            }
            inFlightHosts.remove(hostId)
        }
    }

    /// Compare new agent_status against previous snapshot for the
    /// host. For any workspace that flipped from non-blocked (or
    /// unknown/missing) to blocked, post a notification. Skip the
    /// first-ever refresh (no previous snapshot) so we don't fire
    /// for everything that's already blocked when cmux starts up.
    private func detectAgentBlockedTransitions(
        host: HerdrHost,
        newSummaries: [HerdrWorkspaceSummary]
    ) {
        guard let previous = workspacesByHost[host.id] else {
            // First fetch for this host; establish baseline silently.
            return
        }
        let prevStatus: [String: String?] = Dictionary(
            uniqueKeysWithValues: previous.map { ($0.workspaceId, $0.agentStatus) }
        )
        for summary in newSummaries {
            guard summary.agentStatus?.lowercased() == "blocked" else { continue }
            let was = prevStatus[summary.workspaceId]??.lowercased()
            if was == "blocked" { continue }
            postBlockedNotification(host: host, workspace: summary)
        }
    }

    private func postBlockedNotification(
        host: HerdrHost,
        workspace: HerdrWorkspaceSummary
    ) {
        let center = UNUserNotificationCenter.current()
        let title = String(
            localized: "herdr.notify.blocked.title",
            defaultValue: "Herdr agent waiting for input"
        )
        let body = "\(host.displayName) · \(workspace.label)"
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = [
                "cmux.herdr.hostId": host.id.uuidString,
                "cmux.herdr.workspaceId": workspace.workspaceId,
            ]
            let request = UNNotificationRequest(
                identifier: "cmux.herdr.blocked.\(host.id.uuidString).\(workspace.workspaceId)",
                content: content,
                trigger: nil
            )
            center.add(request) { _ in }
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
