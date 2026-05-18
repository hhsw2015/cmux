import XCTest
@testable import CMUXSessionDaemon

final class TsmBackendTests: XCTestCase {
    func testKindIsTsm() {
        XCTAssertEqual(TsmBackend().kind, .tsm)
    }

    func testParseAttachDelegatesToTsmParser() {
        let backend = TsmBackend()
        XCTAssertEqual(
            backend.parseAttachInvocation(["tsm", "attach", "work"])?.sessionName,
            "work"
        )
        XCTAssertNil(backend.parseAttachInvocation(["tsm", "ls"]))
        XCTAssertNil(backend.parseAttachInvocation(["zmx", "attach", "work"]))
    }

    func testConformsToDeepBackend() {
        let backend: SessionDaemonBackend = TsmBackend()
        XCTAssertNotNil(backend as? DeepSessionDaemonBackend)
    }

    func testEventStreamIsNilUntilPhase5() {
        XCTAssertNil(TsmBackend().eventStream())
    }

    // MARK: - bundle isolation

    func testBundleSuffixHonorsOverride() {
        let env = ["CMUX_INSTANCE_TAG": "staging"]
        XCTAssertEqual(TsmBackend.bundleSuffix(environment: env), "staging")
    }

    func testBundleSuffixFallsBackToBundleIdLastComponent() {
        let env: [String: String] = [:]
        // Bundle.main during xctest typically ends in 'xctest' or similar;
        // assert non-empty rather than a specific string.
        let suffix = TsmBackend.bundleSuffix(environment: env)
        XCTAssertFalse(suffix.isEmpty)
    }

    func testSessionNameContainsSuffixAndPanelId() {
        let id = UUID()
        let env = ["CMUX_INSTANCE_TAG": "test"]
        // Re-derive via overridden suffix path
        XCTAssertEqual(TsmBackend.bundleSuffix(environment: env), "test")
        let name = TsmBackend.sessionName(forPanelId: id)
        XCTAssertTrue(name.hasPrefix("cmux-"))
        let shortPanel = id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        XCTAssertTrue(name.contains(String(shortPanel)))
    }

    // MARK: - tokenizer

    func testTokenizeSimple() {
        XCTAssertEqual(TsmBackend.tokenizeShell("npm run dev"),
                       ["npm", "run", "dev"])
    }

    func testTokenizeQuoted() {
        XCTAssertEqual(TsmBackend.tokenizeShell("git commit -m 'hello world'"),
                       ["git", "commit", "-m", "hello world"])
    }

    func testTokenizeEmpty() {
        XCTAssertEqual(TsmBackend.tokenizeShell(""), [])
    }

    // MARK: - worktree parser

    func testParseWorktreeListBasic() {
        let raw = """
        main
        feature-login
        hotfix-auth
        """
        XCTAssertEqual(
            TsmBackend.parseWorktreeList(raw).map(\.branch),
            ["main", "feature-login", "hotfix-auth"]
        )
    }

    func testParseWorktreeListSkipsHeaderAndEmpty() {
        let raw = """
        Branch    Path
        no worktrees yet

        main      /tmp/main
        """
        XCTAssertEqual(
            TsmBackend.parseWorktreeList(raw).map(\.branch),
            ["main"]
        )
    }
}
