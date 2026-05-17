import XCTest
@testable import CMUXZmx

final class TsmArgvParserTests: XCTestCase {
    func testParsesAttach() {
        let parsed = TsmArgvParser.parse(["tsm", "attach", "work"])
        XCTAssertEqual(parsed?.sessionName, "work")
        XCTAssertEqual(parsed?.subcommand, .attach)
    }

    func testParsesNew() {
        let parsed = TsmArgvParser.parse(["tsm", "new", "logs"])
        XCTAssertEqual(parsed?.sessionName, "logs")
        XCTAssertEqual(parsed?.subcommand, .new)
    }

    func testParsesAttachWithFullPath() {
        let parsed = TsmArgvParser.parse(["/opt/homebrew/bin/tsm", "attach", "work"])
        XCTAssertEqual(parsed?.sessionName, "work")
    }

    func testParsesNewWithCommand() {
        let parsed = TsmArgvParser.parse(["tsm", "new", "build", "--", "cargo", "build"])
        XCTAssertEqual(parsed?.sessionName, "build")
        XCTAssertEqual(parsed?.subcommand, .new)
    }

    func testIgnoresShortAliasesThatTsmDoesNotSupport() {
        // tsm only documents `p` for `palette`. attach/detach/new/etc. have
        // no single-letter aliases. Anything that looked like one in zmx
        // must NOT be treated as a binding here.
        XCTAssertNil(TsmArgvParser.parse(["tsm", "a", "work"]))
        XCTAssertNil(TsmArgvParser.parse(["tsm", "n", "work"]))
        XCTAssertNil(TsmArgvParser.parse(["tsm", "d", "work"]))
        XCTAssertNil(TsmArgvParser.parse(["tsm", "k", "work"]))
    }

    func testIgnoresMetaSubcommands() {
        XCTAssertNil(TsmArgvParser.parse(["tsm", "ls"]))
        XCTAssertNil(TsmArgvParser.parse(["tsm", "kill", "foo"]))
        XCTAssertNil(TsmArgvParser.parse(["tsm", "detach", "foo"]))
        XCTAssertNil(TsmArgvParser.parse(["tsm", "rename", "old", "new"]))
        XCTAssertNil(TsmArgvParser.parse(["tsm", "palette"]))
        XCTAssertNil(TsmArgvParser.parse(["tsm", "p"]))
        XCTAssertNil(TsmArgvParser.parse(["tsm", "doctor"]))
        XCTAssertNil(TsmArgvParser.parse(["tsm", "version"]))
        XCTAssertNil(TsmArgvParser.parse(["tsm", "wt"]))
        XCTAssertNil(TsmArgvParser.parse(["tsm", "wt", "add", "feature"]))
        XCTAssertNil(TsmArgvParser.parse(["tsm", "mux", "open", "ws"]))
    }

    func testIgnoresNonTsmCommand() {
        XCTAssertNil(TsmArgvParser.parse(["zsh", "-l"]))
        XCTAssertNil(TsmArgvParser.parse(["zmx", "attach", "foo"]))
    }

    func testSkipsGlobalFlags() {
        let parsed = TsmArgvParser.parse(["tsm", "--verbose", "attach", "work"])
        XCTAssertEqual(parsed?.sessionName, "work")
    }

    func testRequiresSessionName() {
        XCTAssertNil(TsmArgvParser.parse(["tsm", "attach"]))
        XCTAssertNil(TsmArgvParser.parse(["tsm", "new"]))
    }
}
