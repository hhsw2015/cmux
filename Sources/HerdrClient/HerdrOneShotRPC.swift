import Foundation
import os.log

/// One-shot RPC helper. Opens a fresh transport for the host (LocalUDS
/// or SSH stdio via `HerdrTransportFactory`), sends one method call,
/// reads exactly one response, tears the transport down.
///
/// This is the canonical RPC path for the herdr daemon. The daemon's
/// API socket reads ONE line per connection then closes (see
/// herdr/src/api/mod.rs handle_connection), so any caller that tries
/// to multiplex two requests on the same HerdrApiClient gets EPIPE
/// on the second send. Always go through this helper for non-subscribe
/// RPCs; only HerdrEventPump's `events.subscribe` flow keeps a
/// connection long-lived (the daemon transitions that connection into
/// streaming mode).
enum HerdrOneShotRPC {
    /// Fire-and-forget. Used when the broadcast event will reconcile
    /// the resulting state, so we don't care about the response body.
    static func send(
        host: HerdrHost,
        method: String,
        params: [String: Any]
    ) async {
        let startedAt = Date()
        do {
            _ = try await request(host: host, method: method, params: params)
            let durMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            os_log("herdr.oneshot.ok method=%{public}@ session=%{public}@ durMs=%{public}d",
                   method, host.sessionName, durMs)
            #if DEBUG
            cmuxDebugLog("herdr.oneshot ok method=\(method) session=\(host.sessionName) durMs=\(durMs)")
            #endif
        } catch {
            let durMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            os_log("herdr.oneshot.fail method=%{public}@ session=%{public}@ durMs=%{public}d error=%{public}@",
                   method, host.sessionName, durMs, String(describing: error))
            cmuxDebugLog("herdr.oneshot \(method) on \(host.sessionName) failed after \(durMs)ms: \(error)")
        }
    }

    /// Request + response. Throws on transport / API error. Caller
    /// owns retry / classification (HerdrApiError vs transport error).
    static func request(
        host: HerdrHost,
        method: String,
        params: [String: Any]
    ) async throws -> [String: Any] {
        let api = HerdrApiClient(transport: HerdrTransportFactory.make(host: host))
        try await api.start()
        defer { Task { await api.close() } }
        return try await api.request(method: method, params: params)
    }
}
