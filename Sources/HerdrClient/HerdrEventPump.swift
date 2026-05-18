#if DEBUG
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
final class HerdrEventPump {
    static let shared = HerdrEventPump()

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
                let client = HerdrApiClient(transport: HerdrTransportFactory.make(host: host))
                try await client.start()
                try await client.subscribe(["layout.changed", "workspace.closed"])
                clients[socketPath] = client
                cmuxDebugLog("herdr.pump: connected on \(socketPath) (attempt=\(attempt + 1))")

                if attempt > 0 {
                    // Reconnect: re-prime divider lastSeen so a stale
                    // local view doesn't echo back as user drags.
                    primeAllBindings(socketPath: socketPath)
                }

                attempt = 0  // reset backoff on a successful subscribe
                let stream = await client.events
                for await event in stream {
                    handle(event: event)
                }
                cmuxDebugLog("herdr.pump: stream closed on \(socketPath); will reconnect")
                if let oldClient = clients.removeValue(forKey: socketPath) {
                    await oldClient.close()
                }
            } catch {
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

    private func handle(event: HerdrEvent) {
        // Line-protocol uses snake_case event names; some clients use
        // dotted ("layout.changed"). Match both for safety.
        switch event.event {
        case "layout_changed", "layout.changed":
            guard let payload = event.decodeData(HerdrLayoutChangedPayload.self) else {
                cmuxDebugLog("herdr.pump: layout_changed payload decode failed")
                return
            }
            HerdrInboundLayoutSync.apply(tree: payload.tree)
        case "workspace_closed", "workspace.closed":
            guard let payload = event.decodeData(HerdrWorkspaceClosedPayload.self) else {
                cmuxDebugLog("herdr.pump: workspace_closed payload decode failed")
                return
            }
            HerdrInboundLayoutSync.applyWorkspaceClosed(workspaceId: payload.workspaceId)
        default:
            break
        }
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
#endif
