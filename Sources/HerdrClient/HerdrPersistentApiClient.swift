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
    private var connectInFlight: Task<HerdrApiClient, Error>?

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

    /// Drop the cached connection. Future requests reconnect.
    /// Called from the registry when a host is removed. Awaits any
    /// in-flight connect Task so we don't leak the ssh subprocess
    /// it spawned (see review HIGH-5 of 3c071dac).
    func close() async {
        if let inFlight = connectInFlight {
            connectInFlight = nil
            inFlight.cancel()
            // Wait for the cancelled connect to settle. If it raced
            // to success despite the cancel, close that api too.
            if let api = try? await inFlight.value {
                await api.close()
            }
        }
        if let api = client {
            client = nil
            await api.close()
        }
    }

    private func ensureConnected() async throws -> HerdrApiClient {
        if let existing = client {
            // Pump may have exited silently if the daemon closed the
            // socket between the previous request and this one (e.g.
            // legacy daemon, transient ssh blip). Trust isClosed and
            // proactively reconnect rather than handing back a dead
            // client whose `request()` would suspend forever — see
            // review CRIT-1 of 3c071dac.
            let dead = await existing.isClosed
            if !dead { return existing }
            client = nil
            await existing.close()
        }
        if let inFlight = connectInFlight {
            return try await inFlight.value
        }
        let task = Task<HerdrApiClient, Error> { [host] in
            let api = HerdrApiClient(transport: HerdrTransportFactory.make(host: host))
            try await api.start()
            return api
        }
        connectInFlight = task
        do {
            let api = try await task.value
            connectInFlight = nil
            client = api
            return api
        } catch {
            connectInFlight = nil
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
