import Foundation
import os.log

/// One-shot RPC facade. Routes every call through the per-host
/// HerdrPersistentApiClient cache so multiple sequential RPCs share
/// ONE ssh subprocess + ONE remote api-bridge instead of paying a
/// fresh ~700ms ssh+bincode handshake per call.
///
/// Daemon protocol: herdr >= 0.6.0-cmux9 keeps the API socket open
/// after each non-streaming response. Older daemons close after one
/// response; the persistent client treats that as a transparent
/// transport disconnect and lazy-reconnects on the next call, so we
/// degrade to roughly the old behaviour automatically without the
/// caller noticing.
///
/// Streaming methods (`events.subscribe`, `pane.wait_for_output`)
/// still own their own connection — see HerdrEventPump and the
/// `wait` helper for those paths.
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
        let client = await HerdrPersistentClientRegistry.shared.client(for: host)
        return try await client.request(method: method, params: params)
    }
}
