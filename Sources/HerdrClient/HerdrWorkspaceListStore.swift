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

    /// Sum of blocked workspaces across every cached host. Used by
    /// `TerminalNotificationStore.unreadCount` to roll into the dock
    /// badge so a blocked remote agent shows up as a number on the
    /// app icon even when the user is in another app.
    var totalBlockedCount: Int {
        workspacesByHost.values.reduce(0) { acc, list in
            acc + list.filter { $0.agentStatus?.lowercased() == "blocked" }.count
        }
    }

    /// Notification posted when blocked count may have changed so
    /// `TerminalNotificationStore` can refresh the dock badge.
    static let blockedCountChangedNotification = Notification.Name(
        "cmux.herdr.blockedCountChanged"
    )

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
                let blockedBefore = totalBlockedCount
                workspacesByHost[hostId] = summaries
                lastErrorByHost.removeValue(forKey: hostId)
                if totalBlockedCount != blockedBefore {
                    NotificationCenter.default.post(
                        name: Self.blockedCountChangedNotification,
                        object: nil
                    )
                }
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
        guard HerdrNotificationSettings.blockedNotificationsEnabled else { return }
        let transitioned = Self.blockedTransitions(
            previous: workspacesByHost[host.id],
            current: newSummaries
        )
        for summary in transitioned {
            postBlockedNotification(host: host, workspace: summary)
        }
        // Reverse: any workspace that was blocked but isn't anymore
        // (or vanished) should drop its pending notification so the
        // notification center doesn't accumulate stale alerts.
        let resolved = Self.resolvedBlockedWorkspaceIds(
            previous: workspacesByHost[host.id],
            current: newSummaries
        )
        if !resolved.isEmpty {
            let ids = resolved.map { "cmux.herdr.blocked.\(host.id.uuidString).\($0)" }
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: ids)
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    /// Workspaces that were blocked in `previous` but are no longer
    /// blocked (or are missing) in `current`. Used to dismiss the
    /// "waiting for input" notification once the agent moves on.
    static func resolvedBlockedWorkspaceIds(
        previous: [HerdrWorkspaceSummary]?,
        current: [HerdrWorkspaceSummary]
    ) -> [String] {
        guard let previous else { return [] }
        let currentStatus: [String: String?] = Dictionary(
            uniqueKeysWithValues: current.map { ($0.workspaceId, $0.agentStatus) }
        )
        return previous.compactMap { prev -> String? in
            guard prev.agentStatus?.lowercased() == "blocked" else { return nil }
            let now = currentStatus[prev.workspaceId]
            // Missing entirely (workspace closed) or status flipped
            // away from blocked.
            if now == nil { return prev.workspaceId }
            if now??.lowercased() != "blocked" { return prev.workspaceId }
            return nil
        }
    }

    /// Pure-function diff used by `detectAgentBlockedTransitions`.
    /// Internal so tests can exercise the transition rules without
    /// spinning up `UNUserNotificationCenter`.
    static func blockedTransitions(
        previous: [HerdrWorkspaceSummary]?,
        current: [HerdrWorkspaceSummary]
    ) -> [HerdrWorkspaceSummary] {
        guard let previous else {
            // First-ever refresh: establish baseline silently.
            return []
        }
        let prevStatus: [String: String?] = Dictionary(
            uniqueKeysWithValues: previous.map { ($0.workspaceId, $0.agentStatus) }
        )
        return current.filter { summary in
            guard summary.agentStatus?.lowercased() == "blocked" else { return false }
            let was = prevStatus[summary.workspaceId]??.lowercased()
            return was != "blocked"
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
