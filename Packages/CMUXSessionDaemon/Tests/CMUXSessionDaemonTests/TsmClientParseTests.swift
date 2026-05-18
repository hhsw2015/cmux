import XCTest
@testable import CMUXSessionDaemon

final class TsmClientParseTests: XCTestCase {
    func testParseSimpleList() {
        let raw = """
        editor
        server
        tests
        """
        XCTAssertEqual(
            TsmClient.parseListOutput(raw),
            ["editor", "server", "tests"]
        )
    }

    func testParseStripsBullets() {
        let raw = """
        ● editor
        ○ server  2h
        """
        XCTAssertEqual(
            TsmClient.parseListOutput(raw),
            ["editor", "server"]
        )
    }

    func testParseStripsAnsi() {
        let raw = "\u{1B}[32m●\u{1B}[0m editor\n\u{1B}[31m○\u{1B}[0m server"
        XCTAssertEqual(
            TsmClient.parseListOutput(raw),
            ["editor", "server"]
        )
    }

    func testParseDropsHeaderRows() {
        let raw = """
        Name        Status
        editor      running
        server      detached
        """
        XCTAssertEqual(
            TsmClient.parseListOutput(raw),
            ["editor", "server"]
        )
    }

    func testParseEmpty() {
        XCTAssertEqual(TsmClient.parseListOutput(""), [])
        XCTAssertEqual(TsmClient.parseListOutput("\n\n"), [])
    }
}
