import XCTest
@testable import CMUXZmx

final class ZmxSystemScannerTests: XCTestCase {
    func testScanReturnsArrayOfLiveAttaches() {
        // Pure smoke: scanning a host without any running zmx returns [], not crash.
        let result = ZmxSystemScanner.scan()
        for entry in result {
            XCTAssertGreaterThan(entry.pid, 0)
            XCTAssertFalse(entry.sessionName.isEmpty)
            XCTAssertFalse(entry.argv.isEmpty)
        }
    }
}
