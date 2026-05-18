import XCTest
@testable import cmux

/// Live integration tests against a real herdr daemon. Skipped unless
/// `CMUX_HERDR_LIVE_SOCKET` env var points to a herdr API socket.
///
/// To run locally:
///   ~/.local/bin/herdr-cmux --session cmux-test server &
///   CMUX_HERDR_LIVE_SOCKET=~/.config/herdr/sessions/cmux-test/herdr.sock \
///     xcodebuild test -only-testing:cmuxTests/HerdrApiClientLiveTests
///
/// CI doesn't run these (no daemon available).
final class HerdrApiClientLiveTests: XCTestCase {
    private var socketPath: String?

    override func setUp() async throws {
        let raw = ProcessInfo.processInfo.environment["CMUX_HERDR_LIVE_SOCKET"]
        socketPath = (raw as NSString?)?.expandingTildeInPath
        if socketPath == nil {
            throw XCTSkip("CMUX_HERDR_LIVE_SOCKET not set")
        }
    }

    func testPingReturnsServerVersion() async throws {
        let path = try XCTUnwrap(socketPath)
        let transport = LocalUDSTransport(socketPath: path)
        let client = HerdrApiClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }
        let info = try await client.ping()
        XCTAssertFalse(info.version.isEmpty)
        XCTAssertGreaterThan(info.protocolVersion, 0)
    }

    func testListWorkspacesRoundTrips() async throws {
        let path = try XCTUnwrap(socketPath)
        let transport = LocalUDSTransport(socketPath: path)
        let client = HerdrApiClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }
        let result = try await client.request(method: "workspace.list", params: [:])
        XCTAssertEqual(result["type"] as? String, "workspace_list")
        // workspaces array exists (may be empty)
        XCTAssertNotNil(result["workspaces"])
    }

    func testSubscribeEmitsLifecycleEvents() async throws {
        let path = try XCTUnwrap(socketPath)
        let transport = LocalUDSTransport(socketPath: path)
        let client = HerdrApiClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }
        try await client.subscribe(["workspace.created"])

        // Trigger a workspace.create on the same client to fire the event.
        async let triggered: Bool = {
            try? await Task.sleep(nanoseconds: 100_000_000)
            _ = try? await client.request(
                method: "workspace.create",
                params: ["focus": false, "label": "ApiClientLiveTest"]
            )
            return true
        }()

        var received: HerdrEvent?
        let timeout = Date().addingTimeInterval(5.0)
        for await ev in await client.events {
            if ev.event == "workspace_created" {
                received = ev
                break
            }
            if Date() > timeout { break }
        }
        _ = await triggered
        XCTAssertNotNil(received, "workspace_created event should arrive within 5s")
    }
}
