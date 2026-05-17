import XCTest
@testable import CMUXZmx

final class ZmxArgvParserTests: XCTestCase {
    func testParsesAttachWithBareBinary() {
        let parsed = ZmxArgvParser.parse(["zmx", "attach", "work"])
        XCTAssertEqual(parsed?.sessionName, "work")
        XCTAssertEqual(parsed?.subcommand, .attach)
        XCTAssertEqual(parsed?.detached, false)
    }

    func testParsesAttachWithFullPath() {
        let parsed = ZmxArgvParser.parse(["/opt/homebrew/bin/zmx", "attach", "work"])
        XCTAssertEqual(parsed?.sessionName, "work")
    }

    func testParsesShortAlias() {
        let parsed = ZmxArgvParser.parse(["zmx", "a", "build"])
        XCTAssertEqual(parsed?.sessionName, "build")
        XCTAssertEqual(parsed?.subcommand, .attach)
    }

    func testParsesRunDetached() {
        let parsed = ZmxArgvParser.parse(["zmx", "run", "-d", "logs", "tail", "-f", "/tmp/log"])
        XCTAssertEqual(parsed?.sessionName, "logs")
        XCTAssertEqual(parsed?.subcommand, .run)
        XCTAssertEqual(parsed?.detached, true)
    }

    func testIgnoresNonZmxCommand() {
        XCTAssertNil(ZmxArgvParser.parse(["zsh", "-l"]))
        XCTAssertNil(ZmxArgvParser.parse(["claude", "--resume", "abc"]))
    }

    func testIgnoresZmxMetaCommands() {
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "ls"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "kill", "foo"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "send", "foo", "ls\n"]))
    }

    func testHandlesGlobalFlagsBeforeSubcommand() {
        let parsed = ZmxArgvParser.parse(["zmx", "--verbose", "attach", "work"])
        XCTAssertEqual(parsed?.sessionName, "work")
    }

    func testHandlesDoubleDashTerminator() {
        let parsed = ZmxArgvParser.parse(["zmx", "attach", "work", "--", "zsh", "-l"])
        XCTAssertEqual(parsed?.sessionName, "work")
    }

    func testRequiresSessionName() {
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "attach"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "attach", "--fish"]))
    }

    func testRunWithFishFlag() {
        let parsed = ZmxArgvParser.parse(["zmx", "run", "--fish", "shell", "fish"])
        XCTAssertEqual(parsed?.sessionName, "shell")
        XCTAssertEqual(parsed?.subcommand, .run)
    }
}
