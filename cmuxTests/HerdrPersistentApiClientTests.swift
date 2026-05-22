import XCTest
@testable import cmux

/// Locks the persistent-api-bridge contract from cmux task #247:
/// multiple sequential RPCs through HerdrPersistentApiClient share
/// ONE underlying transport connection. Without this, each RPC pays
/// a fresh ssh subprocess + bincode handshake (~700ms) and saturates
/// the SSH master during a divider drag.
///
/// The test stands up a tiny UDS daemon mock on /tmp that counts
/// inbound connections and replies to one-line JSON-RPC requests,
/// then drives a HerdrPersistentApiClient against a localUDS host
/// pointing at that socket.
final class HerdrPersistentApiClientTests: XCTestCase {
    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        // The registry is a process-wide singleton. Clear it before
        // every test so state from a previous case (e.g. a cached
        // client whose mock daemon already exited) can't poison the
        // current one (review MED-10 of 3c071dac).
        HerdrPersistentClientRegistry.shared.forgetAll()
    }


    // MARK: - mock daemon

    /// Tiny UDS server. Each accepted connection enters a read-line /
    /// write-response loop until the peer closes — same protocol the
    /// real herdr daemon implements at >= 0.6.0-cmux9. The test
    /// inspects `connectionCount` to assert reuse. With
    /// `closeAfterFirstResponse = true` it mimics legacy daemons that
    /// shut the socket after the first response so we can verify the
    /// persistent client transparently reconnects.
    private final class MockDaemon: @unchecked Sendable {
        let socketPath: String
        let closeAfterFirstResponse: Bool
        private var serverFd: Int32 = -1
        private var loopThread: Thread?
        private let lock = NSLock()
        private var _connectionCount = 0
        private var _running = true

        var connectionCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _connectionCount
        }

        init(socketPath: String, closeAfterFirstResponse: Bool = false) throws {
            self.socketPath = socketPath
            self.closeAfterFirstResponse = closeAfterFirstResponse
            unlink(socketPath)
            let parent = (socketPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(
                atPath: parent, withIntermediateDirectories: true
            )

            serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard serverFd >= 0 else { throw NSError(domain: "mockd", code: 1) }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            socketPath.withCString { p in
                withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                    let copyLen = min(strlen(p), dst.count - 1)
                    memcpy(dst.baseAddress, p, copyLen)
                }
            }
            let bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    Darwin.bind(serverFd, ptr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else { throw NSError(domain: "mockd", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]) }
            guard listen(serverFd, 4) == 0 else { throw NSError(domain: "mockd", code: 3) }

            let thread = Thread { [weak self] in
                self?.serveLoop()
            }
            thread.start()
            loopThread = thread
        }

        deinit {
            stop()
        }

        func stop() {
            lock.lock(); _running = false; lock.unlock()
            if serverFd >= 0 {
                close(serverFd)
                serverFd = -1
            }
            unlink(socketPath)
        }

        private func serveLoop() {
            while true {
                lock.lock(); let running = _running; lock.unlock()
                guard running else { return }
                let clientFd = accept(serverFd, nil, nil)
                if clientFd < 0 { return }
                lock.lock(); _connectionCount += 1; lock.unlock()
                Thread { [weak self] in
                    self?.handleClient(fd: clientFd)
                }.start()
            }
        }

        private func handleClient(fd: Int32) {
            var buf = Data()
            let chunk = 4096
            var raw = [UInt8](repeating: 0, count: chunk)
            while true {
                let n = read(fd, &raw, chunk)
                if n <= 0 {
                    close(fd)
                    return
                }
                buf.append(contentsOf: raw.prefix(n))
                while let nlIndex = buf.firstIndex(of: 0x0A) {
                    let lineRange = buf.startIndex..<nlIndex
                    let line = buf.subdata(in: lineRange)
                    buf.removeSubrange(buf.startIndex...nlIndex)
                    // Always write SOMETHING per inbound line so a
                    // malformed payload doesn't leave the cmux side
                    // hanging forever on a continuation that never
                    // resumes (review HIGH-9 of 3c071dac).
                    let response = makeResponse(for: line)
                        ?? makeFallbackError(for: line)
                    var out = response
                    out.append(0x0A)
                    out.withUnsafeBytes { ptr in
                        _ = write(fd, ptr.baseAddress, out.count)
                    }
                    if closeAfterFirstResponse {
                        close(fd)
                        return
                    }
                }
            }
        }

        private func makeResponse(for line: Data) -> Data? {
            guard
                let parsed = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let id = parsed["id"] as? String,
                let method = parsed["method"] as? String
            else { return nil }
            let body: [String: Any] = [
                "id": id,
                "result": ["type": "echo", "method": method],
            ]
            return try? JSONSerialization.data(withJSONObject: body)
        }

        /// Visible-error response for malformed payloads. Matches the
        /// real daemon's `invalid_request` error envelope so cmux
        /// surfaces it as a HerdrApiError instead of timing out.
        private func makeFallbackError(for line: Data) -> Data {
            let id = (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["id"] as? String ?? ""
            let body: [String: Any] = [
                "id": id,
                "error": [
                    "code": "invalid_request",
                    "message": "mock daemon could not parse payload",
                ],
            ]
            return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        }
    }

    // MARK: - tests

    @MainActor
    func testThreeSequentialRequestsReuseOneConnection() async throws {
        // Use a unique session name and let HerdrHost.localApiSocketPath
        // pick the path; bind the mock daemon there so the production
        // localUDS transport hits it without test-only host plumbing.
        let session = "cmux-persistent-test-\(UUID().uuidString.prefix(8))"
        let host = HerdrHost.localhost(sessionName: String(session))
        let daemon = try MockDaemon(socketPath: host.localApiSocketPath)
        defer { daemon.stop() }

        let persistent = HerdrPersistentApiClient(host: host)

        for i in 0..<3 {
            let resp = try await persistent.request(method: "ping_\(i)", params: [:])
            XCTAssertEqual(resp["type"] as? String, "echo")
            XCTAssertEqual(resp["method"] as? String, "ping_\(i)")
        }

        await persistent.close()

        // The whole point of #247: with the daemon's keepalive support,
        // three RPCs go through ONE connection — the SSH master would
        // not have to re-negotiate per call.
        XCTAssertEqual(daemon.connectionCount, 1,
                       "all three RPCs must share a single connection")
    }

    @MainActor
    func testReconnectsAfterDaemonClosesConnectionPostResponse() async throws {
        // Locks review CRIT-1: HerdrApiClient.pump silently exits when
        // the peer closes the socket; without isClosed propagation the
        // PersistentApiClient would hand back a dead client and the
        // next request() would suspend on a continuation that's never
        // fulfilled. Mock daemon mimics legacy single-shot behaviour
        // (close after each response). Two RPCs must both succeed; the
        // daemon should see two distinct accept()s.
        let session = "cmux-eof-reconnect-\(UUID().uuidString.prefix(8))"
        let host = HerdrHost.localhost(sessionName: String(session))
        let daemon = try MockDaemon(
            socketPath: host.localApiSocketPath,
            closeAfterFirstResponse: true
        )
        defer { daemon.stop() }

        let persistent = HerdrPersistentApiClient(host: host)
        defer { Task { await persistent.close() } }

        let r1 = try await persistent.request(method: "ping_a", params: [:])
        XCTAssertEqual(r1["method"] as? String, "ping_a")

        // Give the post-response close a moment to be observed by
        // HerdrApiClient.pump on our side; persistent client should
        // notice via isClosed and reconnect.
        try await Task.sleep(nanoseconds: 100_000_000)

        let r2 = try await persistent.request(method: "ping_b", params: [:])
        XCTAssertEqual(r2["method"] as? String, "ping_b")

        XCTAssertEqual(daemon.connectionCount, 2,
                       "post-response close must force a reconnect on the next request")
    }

    @MainActor
    func testRegistryReusesClientForSameHost() {
        let host = HerdrHost.localhost(sessionName: "cmux-persistent-registry-test")
        let registry = HerdrPersistentClientRegistry.shared
        let a = registry.client(for: host)
        let b = registry.client(for: host)
        XCTAssertTrue(a === b, "registry must vend the same client for the same host id")
        registry.forget(host: host)
        let c = registry.client(for: host)
        XCTAssertFalse(a === c, "after forget, a fresh client must be vended")
        registry.forget(host: host)
    }
}
