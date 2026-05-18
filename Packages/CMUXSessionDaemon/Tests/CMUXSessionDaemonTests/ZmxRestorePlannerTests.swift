import XCTest
@testable import CMUXSessionDaemon

final class ZmxRestorePlannerTests: XCTestCase {
    func testNoBindingMeansNoop() {
        let action = ZmxRestorePlanner.plan(
            binding: nil,
            environment: env(alive: [])
        )
        XCTAssertEqual(action, .noop)
    }

    func testZmxMissingClearsBinding() {
        let action = ZmxRestorePlanner.plan(
            binding: bind("work", state: .attached),
            environment: ZmxRestorePlanner.Environment(
                zmxBinaryAvailable: false,
                zmxBinaryExecutable: false,
                aliveSessions: []
            )
        )
        XCTAssertEqual(action, .clearBinding(reason: .zmxBinaryMissing))
    }

    func testZmxNotExecutableClearsBinding() {
        let action = ZmxRestorePlanner.plan(
            binding: bind("work", state: .attached),
            environment: ZmxRestorePlanner.Environment(
                zmxBinaryAvailable: true,
                zmxBinaryExecutable: false,
                aliveSessions: []
            )
        )
        XCTAssertEqual(action, .clearBinding(reason: .zmxBinaryNotExecutable))
    }

    func testSessionDeadClearsBinding() {
        let action = ZmxRestorePlanner.plan(
            binding: bind("work", state: .attached),
            environment: env(alive: [])
        )
        XCTAssertEqual(action, .clearBinding(reason: .sessionNotAlive))
    }

    func testAttachedSessionAliveReattaches() {
        let binding = bind("work", state: .attached)
        let action = ZmxRestorePlanner.plan(
            binding: binding,
            environment: env(alive: ["work"])
        )
        XCTAssertEqual(action, .attach(
            argv: ["zmx", "attach", "work"],
            workingDirectory: "/tmp"
        ))
    }

    func testDetachedSessionAliveOffersReattach() {
        let binding = bind("work", state: .detached)
        let action = ZmxRestorePlanner.plan(
            binding: binding,
            environment: env(alive: ["work"])
        )
        XCTAssertEqual(action, .offerReattach(binding: binding))
    }

    func testLostSessionAliveOffersReattach() {
        // Previously marked lost (e.g. concurrent kill+restart), but session
        // came back. Don't auto-attach silently — surface the reattach button.
        let binding = bind("work", state: .lost)
        let action = ZmxRestorePlanner.plan(
            binding: binding,
            environment: env(alive: ["work"])
        )
        XCTAssertEqual(action, .offerReattach(binding: binding))
    }

    // MARK: - helpers

    private func env(alive: Set<String>) -> ZmxRestorePlanner.Environment {
        ZmxRestorePlanner.Environment(
            zmxBinaryAvailable: true,
            zmxBinaryExecutable: true,
            aliveSessions: alive
        )
    }

    private func bind(_ name: String, state: RestorableZmxBinding.AttachState) -> RestorableZmxBinding {
        RestorableZmxBinding(
            workspaceId: UUID(),
            panelId: UUID(),
            zmxSessionName: name,
            zmxBinaryPath: "/usr/local/bin/zmx",
            originalArgv: ["zmx", "attach", name],
            workingDirectory: "/tmp",
            attachState: state
        )
    }
}
