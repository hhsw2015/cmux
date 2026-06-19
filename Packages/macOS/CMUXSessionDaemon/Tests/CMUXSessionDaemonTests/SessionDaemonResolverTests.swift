import XCTest
@testable import CMUXSessionDaemon

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

    func testActiveBackendForTsmRequiresBinary() {
        resolver.setSelectedKind(.tsm)
        // After Phase 1: a backend is returned only if tsm is on PATH.
        // Otherwise we degrade gracefully.
        let backend = resolver.activeBackend()
        if TsmLocator.resolveBinary() == nil {
            XCTAssertNil(backend)
        } else {
            XCTAssertEqual(backend?.kind, .tsm)
        }
    }

    func testActiveDeepBackendForTsmCastSucceeds() {
        resolver.setSelectedKind(.tsm)
        guard TsmLocator.resolveBinary() != nil else {
            return // no tsm on host, can't assert
        }
        XCTAssertNotNil(resolver.activeDeepBackend())
    }

    func testActiveDeepBackendIsNilForZmx() {
        resolver.setSelectedKind(.zmx)
        // ZmxBackend doesn't conform to DeepSessionDaemonBackend; deep
        // features must stay locked even if a backend is active.
        XCTAssertNil(resolver.activeDeepBackend())
    }
}
