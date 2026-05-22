import Foundation
import os.log

/// Long-lived JSON-RPC client cached per host. Reuses one transport
/// (and therefore one ssh subprocess + one remote api-bridge) across
/// many sequential RPCs, replacing HerdrOneShotRPC's
/// connection-per-call model. With herdr daemon >= 0.6.0-cmux9 the
/// API socket loops on the same connection; older daemons close
/// after one response and we transparently reconnect.
///
/// The actor keeps one `HerdrApiClient` (which already multiplexes
/// requests by id over a single transport) per host. On stream loss
/// we drop the cached client and the next caller drives a fresh
/// connection.
actor HerdrPersistentApiClient {
    let host: HerdrHost

    private var client: HerdrApiClient?
    /// Awaiters waiting on the in-flight connect attempt. While
    /// `connecting` is true any new ensureConnected call appends here
    /// instead of spawning its own connect Task. Replaces the prior
    /// `connectInFlight: Task` design so a failed connect can't
    /// "leak" past A's catch and let a parallel D-caller spin up a
    /// second ssh subprocess (review HIGH-4 of 3c071dac).
    private var awaiters: [CheckedContinuation<HerdrApiClient, Error>] = []
    private var connecting = false

    /// Permanent shutdown flag set by `close()`. After this flips,
    /// every future `request()` rejects synchronously instead of
    /// quietly resurrecting the connection. The registry replaces
    /// the instance when a host comes back online, so callers that
    /// hold a stale reference past `forget(host:)` no longer get a
    /// silent ssh re-spawn.
    private var stopped = false

    init(host: HerdrHost) {
        self.host = host
    }

    /// Issue one JSON-RPC request and return its result body.
    /// Reconnects once if the cached connection has been silently
    /// closed (e.g. the daemon was restarted, an ssh hiccup, or the
    /// remote is still on a pre-keepalive herdr).
    func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        var attempts = 0
        while true {
            attempts += 1
            let api = try await ensureConnected()
            do {
                return try await api.request(method: method, params: params)
            } catch is CancellationError {
                // User-initiated cancellation (Task cancelled, view
                // teardown, sign-out). Propagate without retrying —
                // a reconnect here would burn an ssh handshake on a
                // request the caller no longer wants.
                throw CancellationError()
            } catch {
                // Transport-level errors (eof / disconnected) mean the
                // cached client is dead. Drop it and retry once on a
                // fresh connection. Don't retry on application errors
                // (HerdrApiError with daemon-supplied codes like
                // pane_not_found) — those are intentional refusals.
                if attempts < 2, isTransportError(error) {
                    await invalidate(api: api)
                    continue
                }
                throw error
            }
        }
    }

    /// Test seam: returns true once the cached client (if any) has
    /// reported isClosed. Tests poll this instead of sleeping a fixed
    /// duration to wait for pump-side EOF observation.
    func _isCachedClientClosedForTesting() async -> Bool {
        guard let api = client else { return true }
        return await api.isClosed
    }

    /// Permanently shut down. Drains every awaiter with
    /// `disconnected`, closes the cached client, and flips the
    /// `stopped` flag so any LATER `request()` against this instance
    /// rejects synchronously instead of silently re-spawning ssh.
    /// The registry vends a fresh instance for the host on the next
    /// `client(for:)`; that's the supported way to "reopen" a host.
    func close() async {
        stopped = true
        if connecting {
            connecting = false
            let pending = awaiters
            awaiters.removeAll()
            for cont in pending {
                cont.resume(throwing: HerdrApiError(
                    code: "disconnected",
                    message: "persistent client closed during connect"
                ))
            }
        }
        if let api = client {
            client = nil
            await api.close()
        }
    }

    private func ensureConnected() async throws -> HerdrApiClient {
        if stopped {
            throw HerdrApiError(code: "disconnected", message: "persistent client closed")
        }
        // Snapshot the cached client BEFORE any await. If the pump has
        // marked it closed silently (legacy daemon, transient ssh
        // blip) we'll fall through to the connect path. The
        // dead-client cleanup is handled INSIDE the connect-or-wait
        // branch using a one-shot `connecting` flag so two concurrent
        // callers can't both observe the same dead client and both
        // call close() on it.
        if let existing = client, !(await existing.isClosed) {
            return existing
        }
        if connecting {
            return try await withCheckedThrowingContinuation { cont in
                awaiters.append(cont)
            }
        }
        connecting = true
        // Clear and close the dead client (if any) only here, after
        // the connecting flag is set, so a racing caller now lands in
        // the `connecting` branch above instead of duplicating this
        // close() against the same instance.
        if let dead = client {
            client = nil
            await dead.close()
        }
        do {
            let api = HerdrApiClient(transport: HerdrTransportFactory.make(host: host))
            try await api.start()
            // close() may have flipped `stopped` while we were
            // awaiting api.start(). Don't publish the freshly-
            // connected api in that window — close() already drained
            // awaiters and there's no one else to release this api
            // (review MED-4 of cmux 0ca26a896). Tear it down right
            // here.
            if stopped {
                connecting = false
                await api.close()
                throw HerdrApiError(
                    code: "disconnected",
                    message: "persistent client closed during connect"
                )
            }
            client = api
            connecting = false
            // Snapshot awaiters before resuming so a re-entrant call
            // from a resumed continuation can't trip over our list.
            let pending = awaiters
            awaiters.removeAll()
            for cont in pending { cont.resume(returning: api) }
            return api
        } catch {
            connecting = false
            let pending = awaiters
            awaiters.removeAll()
            for cont in pending { cont.resume(throwing: error) }
            throw error
        }
    }

    private func invalidate(api: HerdrApiClient) async {
        // Only invalidate if the client we hold matches what failed.
        // A racing reconnect could already have replaced it.
        if client === api {
            client = nil
        }
        await api.close()
    }

    private nonisolated func isTransportError(_ error: Error) -> Bool {
        if let api = error as? HerdrApiError {
            // Codes set by HerdrApiClient when the underlying transport
            // ends or is closed mid-request.
            return api.code == "eof" || api.code == "disconnected"
        }
        // Any non-HerdrApiError that bubbled up from `transport.send`
        // (CancellationError, IO error, etc.) is treated as transport-
        // level and warrants one reconnect attempt.
        return !(error is HerdrApiError)
    }
}

/// Per-host registry of HerdrPersistentApiClient instances. Keyed by
/// `HerdrHost.id` so the same host config (LocalUDS or sshStdio)
/// always lands on the same client. Removing a host (or detaching the
/// EventPump) calls `forget` to release the connection.
@MainActor
final class HerdrPersistentClientRegistry {
    static let shared = HerdrPersistentClientRegistry()

    private var clients: [HerdrHost.ID: HerdrPersistentApiClient] = [:]

    /// Get or lazily create the persistent client for `host`.
    func client(for host: HerdrHost) -> HerdrPersistentApiClient {
        if let existing = clients[host.id] {
            return existing
        }
        let fresh = HerdrPersistentApiClient(host: host)
        clients[host.id] = fresh
        return fresh
    }

    /// Drop the cached client for `host`. The underlying connection
    /// is closed asynchronously.
    func forget(host: HerdrHost) {
        if let removed = clients.removeValue(forKey: host.id) {
            Task { await removed.close() }
        }
    }

    /// Drop ALL cached clients. Called on app shutdown / sign-out so
    /// we don't leak ssh subprocesses on the next launch.
    func forgetAll() {
        let snapshot = clients
        clients.removeAll()
        for (_, removed) in snapshot {
            Task { await removed.close() }
        }
    }
}
