import Foundation
import UserNotifications

/// One long-lived `events.subscribe` connection per host. Reference-
/// counted so the pump auto-starts when the first herdr-backed
/// workspace registers and tears down after the last one closes.
///
/// If the connection drops (daemon restart, blip), the consumer task
/// loops with capped exponential backoff and re-establishes the
/// subscription. After a successful reconnect we re-prime each
/// binding's `HerdrDividerSync.lastSeen` so the next outbound diff
/// uses the fresh server state instead of stale pre-disconnect ratios.
@MainActor
final class HerdrEventPump: ObservableObject {
    static let shared = HerdrEventPump()

    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case retrying(attempt: Int, lastError: String)
    }

    /// Per-host connection state so the sidebar can show a "?" /
    /// "..." / "" indicator. Keyed by host id (not socket path) so
    /// callers don't have to know the transport.
    @Published private(set) var connectionStateByHost: [UUID: ConnectionState] = [:]

    private var clients: [String: HerdrApiClient] = [:]
    private var consumers: [String: Task<Void, Never>] = [:]
    private var refCounts: [String: Int] = [:]
    /// Per-socket host snapshot so the consumer loop can rebuild a
    /// transport on reconnect without holding the original `HerdrHost`.
    private var hosts: [String: HerdrHost] = [:]

    /// Per-host pending offline-notification timer. Starts when the
    /// host enters retrying; cancelled when it reconnects or the
    /// notification fires.
    private var offlineNotificationTasks: [UUID: Task<Void, Never>] = [:]
    /// Set of host ids that already triggered the offline
    /// notification — used so reconnect can post a follow-up
    /// "back online" alert and avoid duplicate offline alerts.
    private var hostsCurrentlyOffline: Set<UUID> = []

    private static let backoffSequence: [UInt64] = [
        1_000_000_000,   // 1s
        2_000_000_000,   // 2s
        5_000_000_000,   // 5s
        10_000_000_000,  // 10s
    ]

    func acquire(host: HerdrHost) async {
        let socketPath = Self.socketPath(for: host)
        hosts[socketPath] = host
        let count = refCounts[socketPath] ?? 0
        refCounts[socketPath] = count + 1
        if count == 0 {
            startConsumerLoop(socketPath: socketPath)
        }
    }

    func release(host: HerdrHost) async {
        let socketPath = Self.socketPath(for: host)
        guard let count = refCounts[socketPath] else { return }
        if count <= 1 {
            refCounts.removeValue(forKey: socketPath)
            hosts.removeValue(forKey: socketPath)
            consumers[socketPath]?.cancel()
            consumers.removeValue(forKey: socketPath)
            connectionStateByHost.removeValue(forKey: host.id)
            offlineNotificationTasks.removeValue(forKey: host.id)?.cancel()
            hostsCurrentlyOffline.remove(host.id)
            if let client = clients.removeValue(forKey: socketPath) {
                await client.close()
            }
        } else {
            refCounts[socketPath] = count - 1
        }
    }

    /// Update connection state and run notification side-effects
    /// (offline alert after sustained retry, back-online alert when
    /// reconnected). Centralizes mutation so individual call sites
    /// don't need to remember the alerts.
    private func setConnectionState(hostId: UUID, host: HerdrHost?, _ state: ConnectionState) {
        connectionStateByHost[hostId] = state
        switch state {
        case .connected:
            // Reconnected: cancel pending alert, post follow-up if
            // we already alerted as offline.
            offlineNotificationTasks.removeValue(forKey: hostId)?.cancel()
            if hostsCurrentlyOffline.remove(hostId) != nil, let host {
                postBackOnlineNotification(for: host)
            }
        case .retrying(_, let lastError):
            // Schedule offline notification after the configured
            // delay if we don't already have one pending or fired.
            guard let host else { return }
            if hostsCurrentlyOffline.contains(hostId) { return }
            if offlineNotificationTasks[hostId] != nil { return }
            let delay = HerdrNotificationSettings.hostOfflineNotificationDelaySeconds
            offlineNotificationTasks[hostId] = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.connectionStateByHost[hostId] != nil else { return }
                if case .retrying = self.connectionStateByHost[hostId] {
                    self.hostsCurrentlyOffline.insert(hostId)
                    self.offlineNotificationTasks.removeValue(forKey: hostId)
                    self.postOfflineNotification(for: host, reason: lastError)
                }
            }
        case .connecting, .idle:
            break
        }
    }

    private func startConsumerLoop(socketPath: String) {
        consumers[socketPath]?.cancel()
        consumers[socketPath] = Task { @MainActor [weak self] in
            await self?.consumerLoop(socketPath: socketPath)
        }
    }

    private func consumerLoop(socketPath: String) async {
        var attempt = 0
        while !Task.isCancelled, refCounts[socketPath] != nil {
            do {
                guard let host = hosts[socketPath] else { return }
                setConnectionState(hostId: host.id, host: host, .connecting)
                let client = HerdrApiClient(transport: HerdrTransportFactory.make(host: host))
                try await client.start()
                try await client.subscribe([
                    "layout.changed",
                    "workspace.created",
                    "workspace.closed",
                    "workspace.focused",
                    "workspace.renamed",
                    "pane.exited",
                ])
                clients[socketPath] = client
                setConnectionState(hostId: host.id, host: host, .connected)
                cmuxDebugLog("herdr.pump: connected on \(socketPath) (attempt=\(attempt + 1))")

                if attempt > 0 {
                    // Reconnect: re-prime divider lastSeen so a stale
                    // local view doesn't echo back as user drags.
                    primeAllBindings(socketPath: socketPath)
                }

                attempt = 0  // reset backoff on a successful subscribe
                let stream = await client.events
                for await event in stream {
                    handle(event: event, socketPath: socketPath)
                }
                cmuxDebugLog("herdr.pump: stream closed on \(socketPath); will reconnect")
                // Pull the transport-level reason (ssh stderr tail,
                // socket errno, etc.) so the host row can display
                // something better than "eof / api socket closed".
                let reason: String
                let finalStatus = await client.transportStatus()
                if case .error(let detail) = finalStatus {
                    reason = detail
                } else {
                    reason = "stream ended"
                }
                if let host = hosts[socketPath] {
                    setConnectionState(
                        hostId: host.id,
                        host: host,
                        .retrying(attempt: attempt + 1, lastError: reason)
                    )
                }
                if let oldClient = clients.removeValue(forKey: socketPath) {
                    await oldClient.close()
                }
            } catch {
                if let host = hosts[socketPath] {
                    setConnectionState(
                        hostId: host.id,
                        host: host,
                        .retrying(attempt: attempt + 1, lastError: String(describing: error))
                    )
                }
                cmuxDebugLog("herdr.pump: connect failed for \(socketPath) (attempt=\(attempt + 1)): \(error)")
            }
            // Backoff before retry, but bail if released.
            guard !Task.isCancelled, refCounts[socketPath] != nil else { return }
            let delay = Self.backoffSequence[min(attempt, Self.backoffSequence.count - 1)]
            attempt += 1
            try? await Task.sleep(nanoseconds: delay)
        }
    }

    private func primeAllBindings(socketPath: String) {
        for binding in HerdrTabRegistry.shared.allBindings {
            let bindingSocket = Self.socketPath(for: binding.host)
            guard bindingSocket == socketPath else { continue }
            guard let workspace = binding.workspace else { continue }
            HerdrDividerSync.prime(
                binding: binding,
                treeSnapshot: workspace.bonsplitController.treeSnapshot()
            )
        }
    }

    private func handle(event: HerdrEvent, socketPath: String) {
        // Line-protocol uses snake_case event names; some clients use
        // dotted ("layout.changed"). Match both for safety.
        switch event.event {
        case "layout_changed", "layout.changed":
            guard let payload = event.decodeData(HerdrLayoutChangedPayload.self) else {
                cmuxDebugLog("herdr.pump: layout_changed payload decode failed")
                return
            }
            HerdrInboundLayoutSync.apply(tree: payload.tree)
        case "workspace_created", "workspace.created",
             "workspace_focused", "workspace.focused",
             "workspace_renamed", "workspace.renamed":
            invalidateWorkspaceList(socketPath: socketPath, reason: event.event)
        case "workspace_closed", "workspace.closed":
            invalidateWorkspaceList(socketPath: socketPath, reason: event.event)
            guard let payload = event.decodeData(HerdrWorkspaceClosedPayload.self) else {
                cmuxDebugLog("herdr.pump: workspace_closed payload decode failed")
                return
            }
            HerdrInboundLayoutSync.applyWorkspaceClosed(workspaceId: payload.workspaceId)
        case "pane_exited", "pane.exited":
            guard let payload = event.decodeData(HerdrPaneExitedPayload.self) else {
                cmuxDebugLog("herdr.pump: pane_exited payload decode failed")
                return
            }
            // Daemon keeps the pane alive after the child process
            // dies (tmux semantics). We flag the panel so it can
            // render an "exited" badge while the PTY pipe + UI
            // remain valid.
            guard let host = hosts[socketPath] else { return }
            HerdrPanelRegistry.shared.markExited(host: host, paneId: payload.paneId)
            cmuxDebugLog(
                "herdr.pump: pane_exited \(payload.paneId) in workspace \(payload.workspaceId)"
            )
        default:
            break
        }
    }

    /// Refresh the sidebar's cached workspace list for the host that
    /// owns this socket. The list store keys on host id; we look it
    /// up via the cached host snapshot.
    private func invalidateWorkspaceList(socketPath: String, reason: String) {
        guard let host = hosts[socketPath] else { return }
        cmuxDebugLog("herdr.pump: refreshing workspace list for \(host.displayName) (\(reason))")
        HerdrWorkspaceListStore.shared.invalidate(hostId: host.id)
        HerdrWorkspaceListStore.shared.refresh(host: host)
    }

    /// Cache key per host. For .localUDS this is the actual UDS path;
    /// for .sshStdio it's a synthetic key (the would-be local path)
    /// so two SSH hosts pointing at the same `sessionName` but
    /// different `target`s would collide — but registry validation
    /// already rejects that case at host-add time, so a sessionName-
    /// based key is fine.
    private static func socketPath(for host: HerdrHost) -> String {
        host.localApiSocketPath
    }

    private func postOfflineNotification(for host: HerdrHost, reason: String) {
        guard HerdrNotificationSettings.hostOfflineNotificationsEnabled else { return }
        // localhost UDS hangs are usually self-inflicted (user killed
        // the daemon manually). Only notify for remote hosts.
        if case .localUDS = host.transport { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = String(
                localized: "herdr.host.offline.title",
                defaultValue: "Herdr host offline"
            )
            content.body = String(
                localized: "herdr.host.offline.body",
                defaultValue: "\(host.displayName): \(reason)"
            )
            content.userInfo = [
                "cmux.herdr.kind": "hostOffline",
                "cmux.herdr.hostId": host.id.uuidString,
            ]
            let request = UNNotificationRequest(
                identifier: "cmux.herdr.host.offline.\(host.id.uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request) { _ in }
        }
    }

    private func postBackOnlineNotification(for host: HerdrHost) {
        guard HerdrNotificationSettings.hostOfflineNotificationsEnabled else { return }
        if case .localUDS = host.transport { return }
        let center = UNUserNotificationCenter.current()
        // Drop the offline notification if it's still showing.
        center.removeDeliveredNotifications(
            withIdentifiers: ["cmux.herdr.host.offline.\(host.id.uuidString)"]
        )
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = String(
                localized: "herdr.host.backOnline.title",
                defaultValue: "Herdr host reconnected"
            )
            content.body = String(
                localized: "herdr.host.backOnline.body",
                defaultValue: "\(host.displayName): connection restored"
            )
            content.userInfo = [
                "cmux.herdr.kind": "hostBackOnline",
                "cmux.herdr.hostId": host.id.uuidString,
            ]
            let request = UNNotificationRequest(
                identifier: "cmux.herdr.host.backOnline.\(host.id.uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request) { _ in }
        }
    }
}
