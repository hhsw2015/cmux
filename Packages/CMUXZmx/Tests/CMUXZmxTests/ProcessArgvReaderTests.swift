import XCTest
@testable import CMUXZmx

final class ProcessArgvReaderTests: XCTestCase {
    func testReadsCurrentProcessArgv() {
        let argv = ProcessArgvReader.argv(forPid: getpid())
        XCTAssertNotNil(argv)
        XCTAssertFalse(argv?.isEmpty ?? true)
    }

    func testReturnsNilForInvalidPid() {
        let argv = ProcessArgvReader.argv(forPid: -1)
        XCTAssertNil(argv)
    }

    func testReturnsNilForZeroPid() {
        let argv = ProcessArgvReader.argv(forPid: 0)
        XCTAssertNil(argv)
    }
}
