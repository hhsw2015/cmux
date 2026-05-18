import XCTest
@testable import CMUXSessionDaemon

/// Test backend that returns a scripted sequence of session lists.
actor ScriptedBackendStorage {
    private var pending: [Result<[DaemonSession], any Error>]
    init(_ pending: [Result<[DaemonSession], any Error>]) {
        self.pending = pending
    }
    func next() throws -> [DaemonSession] {
        guard !pending.isEmpty else { return [] }
        return try pending.removeFirst().get()
    }
}

final class ScriptedBackend: SessionDaemonBackend, @unchecked Sendable {
    let kind = SessionDaemonKind.zmx
    let storage: ScriptedBackendStorage

    init(_ pending: [Result<[DaemonSession], any Error>]) {
        self.storage = ScriptedBackendStorage(pending)
    }

    func locateBinary() -> URL? { nil }
    func version() -> String? { nil }
    func parseAttachInvocation(_ argv: [String]) -> ParsedDaemonAttach? { nil }
    func isAlive(_ name: String) async -> Bool { false }
    func kill(_ name: String, force: Bool) async throws {}

    func listSessions() async throws -> [DaemonSession] {
        try await storage.next()
    }

    static func session(_ name: String) -> DaemonSession {
        DaemonSession(name: name, pid: nil, cmd: "", dir: "",
                      state: .running, clientCount: 0, agentKind: nil)
    }
}

actor EventCollector {
    private(set) var events: [DaemonEvent] = []
    func append(_ event: DaemonEvent) {
        events.append(event)
    }
    func snapshot() -> [DaemonEvent] {
        events
    }
}

final class PollingDaemonEventSourceTests: XCTestCase {
    func testEmitsCreatedAndExitedOnDiff() async throws {
        let backend = ScriptedBackend([
            .success([ScriptedBackend.session("a")]),
            .success([ScriptedBackend.session("a"), ScriptedBackend.session("b")]),
            .success([ScriptedBackend.session("b")]),
        ])
        let source = PollingDaemonEventSource(backend: backend, interval: 0.05)
        let stream = await source.events()

        let collector = EventCollector()
        let task = Task {
            for await event in stream {
                await collector.append(event)
                if await collector.snapshot().count >= 3 { break }
            }
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await source.stop()
        task.cancel()

        let events = await collector.snapshot()
        let createdNames = events.compactMap { event -> String? in
            if case .sessionCreated(let name, _, _) = event { return name }
            return nil
        }
        let exitedNames = events.compactMap { event -> String? in
            if case .sessionExited(let name, _) = event { return name }
            return nil
        }
        XCTAssertTrue(createdNames.contains("a"))
        XCTAssertTrue(createdNames.contains("b"))
        XCTAssertTrue(exitedNames.contains("a"))
    }

    func testIgnoresBackendFailures() async throws {
        struct Boom: Error {}
        let backend = ScriptedBackend([
            .failure(Boom()),
            .failure(Boom()),
            .success([ScriptedBackend.session("ok")]),
        ])
        let source = PollingDaemonEventSource(backend: backend, interval: 0.03)
        let stream = await source.events()

        let collector = EventCollector()
        let task = Task {
            for await event in stream {
                await collector.append(event)
                break
            }
        }
        try? await Task.sleep(nanoseconds: 600_000_000)
        await source.stop()
        task.cancel()

        let events = await collector.snapshot()
        guard case .sessionCreated(let name, _, _) = events.first else {
            XCTFail("expected sessionCreated, got \(events)")
            return
        }
        XCTAssertEqual(name, "ok")
    }
}
