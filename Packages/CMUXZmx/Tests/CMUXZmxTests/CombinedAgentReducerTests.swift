import XCTest
@testable import CMUXZmx

final class CombinedAgentReducerTests: XCTestCase {
    private let reducer = CombinedAgentReducer()
    private let panelId = UUID()

    func testFirstUpdateBecomesEntry() {
        let entry = entry(.cmuxHook, status: .running, at: 10)
        let merged = reducer.merge(existing: nil, update: entry)
        XCTAssertEqual(merged, entry)
    }

    func testNewerUpdateWins() {
        let old = entry(.cmuxHook, status: .running, at: 10)
        let new = entry(.tsmEvent, status: .completed, at: 20)
        let merged = reducer.merge(existing: old, update: new)
        XCTAssertEqual(merged.status, .completed)
        XCTAssertEqual(merged.sources, [.cmuxHook, .tsmEvent])
    }

    func testOlderUpdateKeepsExistingButUnionsSources() {
        let old = entry(.cmuxHook, status: .completed, at: 30)
        let stale = entry(.tsmEvent, status: .running, at: 10)
        let merged = reducer.merge(existing: old, update: stale)
        XCTAssertEqual(merged.status, .completed)
        XCTAssertEqual(merged.sources, [.cmuxHook, .tsmEvent])
    }

    func testRemoveDropsSourceAndReturnsNilWhenLast() {
        let entry = entry(.cmuxHook, status: .running, at: 10)
        XCTAssertNil(reducer.remove(existing: entry, source: .cmuxHook))
    }

    func testRemoveKeepsRemainingSources() {
        var two = entry(.cmuxHook, status: .running, at: 10)
        two.sources.insert(.tsmEvent)
        let after = reducer.remove(existing: two, source: .cmuxHook)
        XCTAssertEqual(after?.sources, [.tsmEvent])
    }

    func testSessionNamePreserved() {
        let withName = entry(.cmuxHook, status: .running, at: 10, name: "editor")
        let withoutName = entry(.tsmEvent, status: .running, at: 20, name: nil)
        let merged = reducer.merge(existing: withName, update: withoutName)
        XCTAssertEqual(merged.sessionName, "editor")
    }

    private func entry(
        _ source: CombinedAgentEntry.AgentSource,
        status: CombinedAgentEntry.AgentStatus,
        at offset: TimeInterval,
        name: String? = nil
    ) -> CombinedAgentEntry {
        CombinedAgentEntry(
            panelId: panelId,
            sessionName: name,
            kind: .claude,
            status: status,
            sources: [source],
            lastUpdate: Date(timeIntervalSinceReferenceDate: offset)
        )
    }
}
