import XCTest
@testable import cmux

final class ClosePanelReasonTests: XCTestCase {
    func testHonorsKeepAliveTruthTable() {
        XCTAssertTrue(ClosePanelReason.userExplicit.honorsKeepAlive)
        XCTAssertTrue(ClosePanelReason.automated.honorsKeepAlive)
        XCTAssertFalse(ClosePanelReason.userTerminate.honorsKeepAlive)
        XCTAssertFalse(ClosePanelReason.parentRemoved.honorsKeepAlive)
    }
}
