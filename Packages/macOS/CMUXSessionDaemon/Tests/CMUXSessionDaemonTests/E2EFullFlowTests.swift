import XCTest
@testable import CMUXSessionDaemon

/// End-to-end test that drives a real backend through the integration's
/// public surface (locator → resolver → backend → events). Skips when no
/// daemon binary is installed; CI without zmx/tsm stays green.
final class E2EFullFlowTests: XCTestCase {
    private var resolver: SessionDaemonResolver!

    override func setUp() {
        super.setUp()
        resolver = SessionDaemonResolver()
        UserDefaults.standard.removeObject(forKey: SessionDaemonResolver.engineDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SessionDaemonResolver.engineDefaultsKey)
        super.tearDown()
    }

    func testEngineNoneShortCircuits() {
        XCTAssertNil(resolver.activeBackend())
        XCTAssertNil(resolver.activeDeepBackend())
    }

    func testEngineSwitchSurvivesMissingBinaries() throws {
        try XCTSkipIf(
            ZmxLocator.resolveBinary() == nil && TsmLocator.resolveBinary() == nil,
            "Neither daemon installed — skipping engine switch flow"
        )
        // Cycle through every engine setting; resolver must never crash.
        resolver.setSelectedKind(.zmx)
        _ = resolver.activeBackend()
        resolver.setSelectedKind(.tsm)
        _ = resolver.activeBackend()
        resolver.setSelectedKind(nil)
        XCTAssertNil(resolver.activeBackend())
    }

    func testZmxBackendListIsConsistentAcrossCalls() async throws {
        try XCTSkipIf(ZmxLocator.resolveBinary() == nil, "zmx not installed")
        resolver.setSelectedKind(.zmx)
        guard let backend = resolver.activeBackend() else {
            XCTFail("zmx backend should resolve")
            return
        }
        let first = try await backend.listSessions()
        let second = try await backend.listSessions()
        // No flakiness: two consecutive calls should match unless the user
        // is racing us. The test environment shouldn't be doing that.
        let firstNames = Set(first.map(\.name))
        let secondNames = Set(second.map(\.name))
        XCTAssertEqual(firstNames, secondNames)
    }

    func testTsmBackendIsDeepWhenInstalled() {
        try? XCTSkipIf(TsmLocator.resolveBinary() == nil, "tsm not installed")
        guard TsmLocator.resolveBinary() != nil else { return }
        resolver.setSelectedKind(.tsm)
        XCTAssertNotNil(resolver.activeDeepBackend())
    }
}
