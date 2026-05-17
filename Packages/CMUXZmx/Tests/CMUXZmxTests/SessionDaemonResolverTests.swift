import XCTest
@testable import CMUXZmx

final class SessionDaemonResolverTests: XCTestCase {
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

    func testDefaultIsNoneWhenUnset() {
        XCTAssertNil(resolver.selectedKind())
    }

    func testNoneStringMapsToNil() {
        UserDefaults.standard.set("none", forKey: SessionDaemonResolver.engineDefaultsKey)
        XCTAssertNil(resolver.selectedKind())
    }

    func testEmptyStringMapsToNil() {
        UserDefaults.standard.set("", forKey: SessionDaemonResolver.engineDefaultsKey)
        XCTAssertNil(resolver.selectedKind())
    }

    func testZmxRoundTrip() {
        resolver.setSelectedKind(.zmx)
        XCTAssertEqual(resolver.selectedKind(), .zmx)
    }

    func testTsmRoundTrip() {
        resolver.setSelectedKind(.tsm)
        XCTAssertEqual(resolver.selectedKind(), .tsm)
    }

    func testSetNilPersistsAsNone() {
        resolver.setSelectedKind(.tsm)
        resolver.setSelectedKind(nil)
        XCTAssertNil(resolver.selectedKind())
    }

    func testActiveBackendNilWhenNoneSelected() {
        XCTAssertNil(resolver.activeBackend())
    }

    func testActiveBackendNilForTsmUntilPhase1() {
        // Phase 0 ships the protocol but no TsmBackend yet; selecting tsm
        // should degrade gracefully instead of crashing.
        resolver.setSelectedKind(.tsm)
        XCTAssertNil(resolver.activeBackend())
    }

    func testActiveDeepBackendIsNilForZmx() {
        resolver.setSelectedKind(.zmx)
        // ZmxBackend doesn't conform to DeepSessionDaemonBackend; deep
        // features must stay locked even if a backend is active.
        XCTAssertNil(resolver.activeDeepBackend())
    }
}
