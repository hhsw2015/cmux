import XCTest
@testable import CMUXZmx

final class ZmxArgvParserTests: XCTestCase {
    func testParsesAttachWithBareBinary() {
        let parsed = ZmxArgvParser.parse(["zmx", "attach", "work"])
        XCTAssertEqual(parsed?.sessionName, "work")
        XCTAssertEqual(parsed?.subcommand, .attach)
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

    func testIgnoresRunSubcommand() {
        // run = "send command without attaching" — not a panel binding
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "run", "logs", "tail", "-f", "/tmp/log"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "r", "logs", "echo"]))
    }

    func testIgnoresNonZmxCommand() {
        XCTAssertNil(ZmxArgvParser.parse(["zsh", "-l"]))
        XCTAssertNil(ZmxArgvParser.parse(["claude", "--resume", "abc"]))
    }

    func testIgnoresZmxMetaCommands() {
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "ls"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "l"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "kill", "foo"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "k", "foo"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "send", "foo", "ls\n"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "s", "foo", "x"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "detach", "foo"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "d", "foo"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "tail", "foo"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "t", "foo"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "history", "foo"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "hi", "foo"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "print", "foo", "msg"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "p", "foo", "msg"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "write", "foo", "/tmp/x"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "wr", "foo", "/tmp/x"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "wait", "foo"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "w", "foo"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "completions", "zsh"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "version"]))
        XCTAssertNil(ZmxArgvParser.parse(["zmx", "help"]))
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

    func testAttachWithFishFlag() {
        let parsed = ZmxArgvParser.parse(["zmx", "attach", "--fish", "shell"])
        XCTAssertEqual(parsed?.sessionName, "shell")
        XCTAssertEqual(parsed?.subcommand, .attach)
    }
}
