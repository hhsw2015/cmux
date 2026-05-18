#if DEBUG
import Foundation

/// Fire-and-forget single-RPC helper. Opens a fresh transport for the
/// host (LocalUDS or SSH stdio via `HerdrTransportFactory`), sends
/// one method call, drops any response, tears the transport down.
///
/// Used by E2d outbound mutation hooks (pane.close, pane.set_split_ratio)
/// where we don't need the response — the daemon will broadcast the
/// resulting state via events.subscribe and our inbound apply path
/// handles it. SSH compatibility falls out of the factory: same code
/// path works for localhost or remote.
enum HerdrOneShotRPC {
    static func send(
        host: HerdrHost,
        method: String,
        params: [String: Any]
    ) async {
        let api = HerdrApiClient(transport: HerdrTransportFactory.make(host: host))
        do {
            try await api.start()
            _ = try await api.request(method: method, params: params)
        } catch {
            // Best-effort: log and let the broadcast event reconcile.
            cmuxDebugLog("herdr.oneshot \(method) on \(host.sessionName) failed: \(error)")
        }
        await api.close()
    }
}
#endif
