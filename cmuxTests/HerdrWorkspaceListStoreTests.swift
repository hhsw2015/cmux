import XCTest
@testable import cmux

@MainActor
final class HerdrWorkspaceListStoreTests: XCTestCase {
    private func ws(_ id: String, status: String?) -> HerdrWorkspaceSummary {
        HerdrWorkspaceSummary(
            workspaceId: id,
            label: id,
            paneCount: 1,
            agentStatus: status,
            activeTabId: nil
        )
    }

    func testFirstRefreshFiresNoTransitions() {
        let result = HerdrWorkspaceListStore.blockedTransitions(
            previous: nil,
            current: [ws("a", status: "blocked"), ws("b", status: "working")]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testIdleToBlockedFires() {
        let result = HerdrWorkspaceListStore.blockedTransitions(
            previous: [ws("a", status: "idle")],
            current: [ws("a", status: "blocked")]
        )
        XCTAssertEqual(result.map { $0.workspaceId }, ["a"])
    }

    func testBlockedToBlockedDoesNotRefire() {
        let result = HerdrWorkspaceListStore.blockedTransitions(
            previous: [ws("a", status: "blocked")],
            current: [ws("a", status: "blocked")]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testBlockedToWorkingToBlockedFiresAgain() {
        let viaWorking = HerdrWorkspaceListStore.blockedTransitions(
            previous: [ws("a", status: "blocked")],
            current: [ws("a", status: "working")]
        )
        XCTAssertTrue(viaWorking.isEmpty)

        let returnsToBlocked = HerdrWorkspaceListStore.blockedTransitions(
            previous: [ws("a", status: "working")],
            current: [ws("a", status: "blocked")]
        )
        XCTAssertEqual(returnsToBlocked.map { $0.workspaceId }, ["a"])
    }

    func testMissingToBlockedFires() {
        let result = HerdrWorkspaceListStore.blockedTransitions(
            previous: [ws("a", status: "idle")],
            current: [ws("a", status: "idle"), ws("new", status: "blocked")]
        )
        XCTAssertEqual(result.map { $0.workspaceId }, ["new"])
    }

    func testCaseInsensitiveStatusComparison() {
        let result = HerdrWorkspaceListStore.blockedTransitions(
            previous: [ws("a", status: "BLOCKED")],
            current: [ws("a", status: "blocked")]
        )
        XCTAssertTrue(result.isEmpty, "BLOCKED -> blocked is the same status, must not re-fire")
    }

    func testNilPreviousStatusToBlockedFires() {
        let result = HerdrWorkspaceListStore.blockedTransitions(
            previous: [ws("a", status: nil)],
            current: [ws("a", status: "blocked")]
        )
        XCTAssertEqual(result.map { $0.workspaceId }, ["a"])
    }

    func testMultipleSimultaneousTransitions() {
        let result = HerdrWorkspaceListStore.blockedTransitions(
            previous: [
                ws("a", status: "working"),
                ws("b", status: "blocked"),
                ws("c", status: "idle"),
            ],
            current: [
                ws("a", status: "blocked"),
                ws("b", status: "blocked"),
                ws("c", status: "blocked"),
            ]
        )
        XCTAssertEqual(Set(result.map { $0.workspaceId }), ["a", "c"])
    }
}
