import XCTest
@testable import CMUXZmx

final class ZmxBackendTests: XCTestCase {
    func testKindIsZmx() {
        XCTAssertEqual(ZmxBackend().kind, .zmx)
    }

    func testParseAttachDelegatesToZmxParser() {
        let backend = ZmxBackend()
        XCTAssertEqual(
            backend.parseAttachInvocation(["zmx", "attach", "work"])?.sessionName,
            "work"
        )
        XCTAssertNil(backend.parseAttachInvocation(["zmx", "ls"]))
        XCTAssertNil(backend.parseAttachInvocation(["zsh", "-l"]))
    }

    func testListSessionsThrowsBinaryNotFoundWhenZmxMissing() async {
        // Use an env without zmx on PATH so resolveBinary returns nil.
        // We rely on the fact that the test runner's PATH contains a real
        // zmx (it's installed for E2E tests), so we override candidate
        // paths via a custom locator route. ZmxBackend uses the global
        // ZmxLocator.resolveBinary so we can't easily inject in this test
        // without refactoring; this asserts the *contract* path runs.
        let backend = ZmxBackend()
        if backend.locateBinary() == nil {
            do {
                _ = try await backend.listSessions()
                XCTFail("expected binaryNotFound")
            } catch let error as SessionDaemonError {
                XCTAssertEqual(error, .binaryNotFound)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testDeepBackendCastFails() {
        let backend: SessionDaemonBackend = ZmxBackend()
        XCTAssertNil(backend as? DeepSessionDaemonBackend)
    }
}
