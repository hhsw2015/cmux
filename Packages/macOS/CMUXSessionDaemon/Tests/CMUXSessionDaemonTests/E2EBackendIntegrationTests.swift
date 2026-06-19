import XCTest
@testable import CMUXSessionDaemon

/// E2E-ish tests that exercise a real daemon binary when available on the
/// host. Marked as no-op when the binary isn't installed so CI without zmx
/// stays green; adopters running these locally pre-merge get full coverage.
///
/// Run policy:
///   - swift test                 → skips if zmx absent (CI default)
///   - swift test --filter E2E    → skips if zmx absent
///   - export CMUX_E2E_REQUIRE_ZMX=1; swift test → fails if zmx absent
final class E2EBackendIntegrationTests: XCTestCase {
    private var backend: ZmxBackend!
    private var hasZmx: Bool { backend.locateBinary() != nil }

    override func setUp() {
        super.setUp()
        backend = ZmxBackend()
        if !hasZmx, ProcessInfo.processInfo.environment["CMUX_E2E_REQUIRE_ZMX"] == "1" {
            XCTFail("CMUX_E2E_REQUIRE_ZMX=1 but no zmx binary found")
        }
    }

    func testListSessionsAgainstLiveDaemon() async throws {
        try XCTSkipIf(!hasZmx, "zmx not installed; skipping E2E")
        // Smoke: just confirm the backend can talk to the daemon without
        // throwing. Output may be empty (no live sessions on the test host).
        _ = try await backend.listSessions()
    }

    func testIsAliveForUnknownSession() async throws {
        try XCTSkipIf(!hasZmx, "zmx not installed; skipping E2E")
        let result = await backend.isAlive("cmux-e2e-nonexistent-\(UUID().uuidString)")
        XCTAssertFalse(result)
    }

    func testKillUnknownSessionThrows() async throws {
        try XCTSkipIf(!hasZmx, "zmx not installed; skipping E2E")
        do {
            try await backend.kill("cmux-e2e-nonexistent-\(UUID().uuidString)", force: true)
            // zmx kill of an unknown session may or may not be an error
            // depending on version; we don't assert outcome, only that the
            // process completes without panicking the runtime.
        } catch is SessionDaemonError {
            // expected for some zmx versions
        }
    }
}
