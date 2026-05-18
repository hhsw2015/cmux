#if DEBUG
import Foundation

/// One long-lived `events.subscribe` connection per host. Reference-
/// counted so the pump auto-starts when the first herdr-backed
/// workspace registers and tears down after the last one closes.
///
/// Currently pumps `layout.changed` only. Future events (PaneCreated,
/// PaneRenamed, agent_status_changed) plug in via `handle(event:)`.
@MainActor
final class HerdrEventPump {
    static let shared = HerdrEventPump()

    private var clients: [String: HerdrApiClient] = [:]
    private var consumers: [String: Task<Void, Never>] = [:]
    private var refCounts: [String: Int] = [:]

    func acquire(host: HerdrHost) async {
        let socketPath = Self.socketPath(for: host)
        let count = refCounts[socketPath] ?? 0
        refCounts[socketPath] = count + 1
        if count == 0 {
            await start(socketPath: socketPath)
        }
    }

    func release(host: HerdrHost) async {
        let socketPath = Self.socketPath(for: host)
        guard let count = refCounts[socketPath] else { return }
        if count <= 1 {
            refCounts.removeValue(forKey: socketPath)
            consumers[socketPath]?.cancel()
            consumers.removeValue(forKey: socketPath)
            if let client = clients.removeValue(forKey: socketPath) {
                await client.close()
            }
        } else {
            refCounts[socketPath] = count - 1
        }
    }

    private func start(socketPath: String) async {
        let client = HerdrApiClient(transport: LocalUDSTransport(socketPath: socketPath))
        do {
            try await client.start()
            try await client.subscribe(["layout.changed"])
            clients[socketPath] = client
            let stream = await client.events
            consumers[socketPath] = Task { @MainActor [weak self] in
                for await event in stream {
                    self?.handle(event: event)
                }
            }
            cmuxDebugLog("herdr.pump: started on \(socketPath)")
        } catch {
            cmuxDebugLog("herdr.pump: start failed for \(socketPath): \(error)")
            refCounts.removeValue(forKey: socketPath)
        }
    }

    private func handle(event: HerdrEvent) {
        // Both rename styles for safety: line-protocol uses snake_case
        // ("layout_changed"), some clients use dotted ("layout.changed").
        guard event.event == "layout_changed" || event.event == "layout.changed" else {
            return
        }
        guard let payload = event.decodeData(HerdrLayoutChangedPayload.self) else {
            cmuxDebugLog("herdr.pump: layout_changed payload decode failed")
            return
        }
        HerdrInboundLayoutSync.apply(tree: payload.tree)
    }

    private static func socketPath(for host: HerdrHost) -> String {
        (("~/.config/herdr/sessions/" + host.sessionName + "/herdr.sock") as NSString)
            .expandingTildeInPath
    }
}
#endif
