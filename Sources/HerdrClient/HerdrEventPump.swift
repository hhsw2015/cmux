import Foundation

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
            if let client = clients.removeValue(forKey: socketPath) {
                await client.close()
            }
        } else {
            refCounts[socketPath] = count - 1
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
                connectionStateByHost[host.id] = .connecting
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
                connectionStateByHost[host.id] = .connected
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
                    connectionStateByHost[host.id] = .retrying(
                        attempt: attempt + 1,
                        lastError: reason
                    )
                }
                if let oldClient = clients.removeValue(forKey: socketPath) {
                    await oldClient.close()
                }
            } catch {
                if let host = hosts[socketPath] {
                    connectionStateByHost[host.id] = .retrying(
                        attempt: attempt + 1,
                        lastError: String(describing: error)
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
            // No UI surfacing yet — herdr keeps the pane alive after
            // process exit (tmux semantics), so cmux's panel and PTY
            // pipe stay valid. Once we have a "process exited"
            // visual indicator on TerminalPanel we can flag it here.
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
}
