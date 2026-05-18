import XCTest
@testable import cmux
@testable import CMUXSessionDaemon

/// Live integration tests against a real cmh fork daemon. Skipped
/// unless `CMUX_HERDR_LIVE_SOCKET` is set (matching the existing
/// HerdrApiClientLiveTests pattern). The corresponding session must
/// already be running; the test creates and destroys one workspace.
///
/// To run locally:
///   ~/.local/bin/herdr-cmux --session cmux-livetest server &
///   CMUX_HERDR_LIVE_SOCKET=~/.config/herdr/sessions/cmux-livetest/herdr.sock \
///   CMUX_HERDR_BIN=~/.local/bin/herdr-cmux \
///     xcodebuild test -only-testing:cmuxTests/HerdrBackendLiveTests
final class HerdrBackendLiveTests: XCTestCase {
    private var socketPath: String?
    private var binPath: String?

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        socketPath = (env["CMUX_HERDR_LIVE_SOCKET"] as NSString?)?.expandingTildeInPath
        binPath = (env["CMUX_HERDR_BIN"] as NSString?)?.expandingTildeInPath
        if socketPath == nil || binPath == nil {
            throw XCTSkip("CMUX_HERDR_LIVE_SOCKET and CMUX_HERDR_BIN must both be set")
        }
    }

    func testListSessionsRoundTripsAfterCreateAndClose() async throws {
        let bin = try XCTUnwrap(binPath)

        // Derive session name from socket path
        // (~/.config/herdr/sessions/<name>/herdr.sock).
        let socket = try XCTUnwrap(socketPath)
        let sessionName = (socket as NSString).deletingLastPathComponent
            .components(separatedBy: "/").last ?? "cmux-livetest"

        let host = HerdrHost(
            id: UUID(),
            displayName: "live-test",
            transport: .localUDS,
            sessionName: sessionName,
            addedAt: Date()
        )
        let backend = try HerdrBackend(host: host, executablePath: bin)
        try await backend.start()
        defer { Task { await backend.close() } }

        // Sessions before create — at least empty.
        let before = try await backend.listSessions()
        let beforeIds = Set(before.map(\.name))

        // Create workspace via api directly (one-line; HerdrBackend
        // doesn't expose workspace creation today).
        let api = HerdrApiClient(transport: LocalUDSTransport(socketPath: socket))
        try await api.start()
        defer { Task { await api.close() } }
        let createResult = try await api.request(
            method: "workspace.create",
            params: ["focus": false, "label": "BackendLiveTest"]
        )
        let workspace = createResult["workspace"] as? [String: Any]
        let workspaceId = try XCTUnwrap(workspace?["workspace_id"] as? String)
        XCTAssertFalse(beforeIds.contains(workspaceId), "new workspace id must be unique")

        // listSessions should now include the new workspace.
        let after = try await backend.listSessions()
        XCTAssertTrue(
            after.contains { $0.name == workspaceId },
            "newly created workspace should appear in listSessions"
        )

        // isAlive should be true.
        let alive = await backend.isAlive(workspaceId)
        XCTAssertTrue(alive, "isAlive must report newly created workspace as alive")

        // kill should remove it.
        try await backend.kill(workspaceId, force: false)
        // Tiny delay for the close to propagate.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let final = try await backend.listSessions()
        XCTAssertFalse(
            final.contains { $0.name == workspaceId },
            "killed workspace should disappear from listSessions"
        )
    }

    func testRemoteHostThrowsRemoteNotSupportedYet() {
        let bin = "/nonexistent/bin"
        let host = HerdrHost(
            id: UUID(),
            displayName: "remote",
            transport: .sshStdio(target: "ignored"),
            sessionName: "ignored",
            addedAt: Date()
        )
        XCTAssertThrowsError(try HerdrBackend(host: host, executablePath: bin)) { err in
            XCTAssertEqual(err as? HerdrBackendError, .remoteNotSupportedYet)
        }
    }
}
