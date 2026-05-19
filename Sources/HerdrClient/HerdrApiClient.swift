import Foundation

/// Errors returned by the herdr API socket. The wire `code` (e.g.
/// `pane_not_found`) is preserved verbatim so callers can match on it.
struct HerdrApiError: Error, Equatable {
    let code: String
    let message: String
}

/// A pushed event from a subscription. `event` is herdr's wire name
/// (e.g. `workspace_created` or `pane.output_matched`); `data` is the
/// raw JSON payload — typed decoders live in higher layers.
struct HerdrEvent: Sendable {
    let event: String
    let data: [String: Any]?

    /// Decode the data payload as a particular Codable type.
    /// Returns nil if `data` is missing or the shape doesn't match.
    func decodeData<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = self.data else { return nil }
        guard let bytes = try? JSONSerialization.data(withJSONObject: data) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: bytes)
    }
}

/// Line-delimited JSON-RPC client over a `HerdrTransport`. Owns the
/// request id counter, multiplexes pending request continuations, and
/// pushes subscription events into a single shared stream.
///
/// Wire format (from herdr SOCKET_API.md):
///   - request:  `{ "id": "...", "method": "...", "params": {...} }\n`
///   - response: `{ "id": "...", "result": {...} }\n`  or  `{ "id": "...", "error": {...} }\n`
///   - event:    `{ "event": "...", "data": {...} }\n`
actor HerdrApiClient {
    private let transport: any HerdrTransport
    private var nextId: Int = 1
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var pumpTask: Task<Void, Never>?

    /// Stream of pushed events from any active subscription. Single
    /// consumer; if you need fan-out, wire a multiplexer above.
    let events: AsyncStream<HerdrEvent>
    private let eventsContinuation: AsyncStream<HerdrEvent>.Continuation

    init(transport: any HerdrTransport) {
        self.transport = transport
        var continuation: AsyncStream<HerdrEvent>.Continuation!
        self.events = AsyncStream { c in continuation = c }
        self.eventsContinuation = continuation
    }

    /// Connect the underlying transport and start reading frames.
    func start() async throws {
        try await transport.connect()
        let incoming = await transport.incoming
        pumpTask = Task { [weak self] in
            await self?.pump(incoming)
        }
    }

    /// Current transport status (e.g. `.error("ssh exited 255: ...")`).
    /// Used by the event pump to surface a friendly reason after a
    /// silent stream-end disconnect.
    func transportStatus() async -> HerdrTransportStatus {
        await transport.status
    }

    func close() async {
        pumpTask?.cancel()
        pumpTask = nil
        await transport.close()
        // Resume any pending requests with an error so callers don't
        // hang forever after disconnect.
        for (_, cont) in pending {
            cont.resume(throwing: HerdrApiError(code: "disconnected", message: "transport closed"))
        }
        pending.removeAll()
        eventsContinuation.finish()
    }

    /// Ping the daemon. Returns the server-reported version + protocol.
    func ping() async throws -> (version: String, protocolVersion: Int) {
        let result = try await request(method: "ping", params: [:])
        let version = result["version"] as? String ?? ""
        let proto = result["protocol"] as? Int ?? 0
        return (version, proto)
    }

    /// Send a request and await its response result object. The result
    /// dict is the contents of `result` minus the `type` discriminator.
    @discardableResult
    func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        let requestId = "cmux_\(nextId)"
        nextId += 1
        let envelope: [String: Any] = [
            "id": requestId,
            "method": method,
            "params": params,
        ]
        let payload = try JSONSerialization.data(withJSONObject: envelope)
        var line = payload
        line.append(0x0A) // newline
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            pending[requestId] = cont
            Task {
                do {
                    try await transport.send(line)
                } catch {
                    if let cb = pending.removeValue(forKey: requestId) {
                        cb.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Subscribe to one or more event types. The ack is awaited; events
    /// flow into `events` afterwards.
    func subscribe(_ subscriptions: [String]) async throws {
        let typed = subscriptions.map { ["type": $0] }
        _ = try await request(
            method: "events.subscribe",
            params: ["subscriptions": typed]
        )
    }

    // MARK: - frame pump

    private func pump(_ incoming: AsyncStream<Data>) async {
        var buffer = Data()
        for await chunk in incoming {
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineRange = buffer.startIndex..<nl
                let line = buffer.subdata(in: lineRange)
                buffer.removeSubrange(buffer.startIndex...nl)
                handleLine(line)
            }
        }
        // Stream ended (transport closed); release pending callers.
        for (_, cont) in pending {
            cont.resume(throwing: HerdrApiError(code: "eof", message: "api socket closed"))
        }
        pending.removeAll()
        eventsContinuation.finish()
    }

    private func handleLine(_ data: Data) {
        guard !data.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let dict = parsed as? [String: Any]
        else {
            return
        }
        // Subscription event push: { "event": "...", "data": {...} }
        if let eventName = dict["event"] as? String {
            let payload = dict["data"] as? [String: Any]
            eventsContinuation.yield(HerdrEvent(event: eventName, data: payload))
            return
        }
        // Request response: { "id": "...", "result"|"error": {...} }
        guard let id = dict["id"] as? String,
              let cont = pending.removeValue(forKey: id)
        else {
            return
        }
        if let err = dict["error"] as? [String: Any] {
            let code = err["code"] as? String ?? "unknown"
            let message = err["message"] as? String ?? ""
            cont.resume(throwing: HerdrApiError(code: code, message: message))
        } else if let result = dict["result"] as? [String: Any] {
            cont.resume(returning: result)
        } else {
            cont.resume(throwing: HerdrApiError(code: "malformed", message: "no result or error"))
        }
    }
}
