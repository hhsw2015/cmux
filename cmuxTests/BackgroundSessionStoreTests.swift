import XCTest
@testable import cmux

@MainActor
final class BackgroundSessionStoreTests: XCTestCase {
    private var store: BackgroundSessionStore!

    override func setUp() {
        super.setUp()
        store = BackgroundSessionStore()
    }

    func testAddInsertsAndSortsByDetachedAt() {
        let workspaceId = UUID()
        let older = entry(workspaceId: workspaceId, name: "old", at: Date().addingTimeInterval(-100))
        let newer = entry(workspaceId: workspaceId, name: "new", at: Date())
        store.add(older)
        store.add(newer)
        XCTAssertEqual(store.sessions.first?.sessionName, "new")
        XCTAssertEqual(store.sessions.count, 2)
    }

    func testAddDedupesByPanelId() {
        let id = UUID()
        let first = entry(panelId: id, name: "v1", at: Date().addingTimeInterval(-10))
        let second = entry(panelId: id, name: "v2", at: Date())
        store.add(first)
        store.add(second)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.sessionName, "v2")
    }

    func testRemoveByPanelId() {
        let a = entry(name: "a")
        let b = entry(name: "b")
        store.add(a)
        store.add(b)
        store.remove(panelId: a.id)
        XCTAssertEqual(store.sessions.map(\.sessionName), ["b"])
    }

    func testRemoveBySessionName() {
        store.add(entry(name: "alpha"))
        store.add(entry(name: "beta"))
        store.remove(sessionName: "alpha")
        XCTAssertEqual(store.sessions.map(\.sessionName), ["beta"])
    }

    func testContains() {
        XCTAssertFalse(store.contains(sessionName: "x"))
        store.add(entry(name: "x"))
        XCTAssertTrue(store.contains(sessionName: "x"))
    }

    private func entry(
        panelId: UUID = UUID(),
        workspaceId: UUID = UUID(),
        name: String,
        at: Date = Date()
    ) -> BackgroundSessionStore.Entry {
        BackgroundSessionStore.Entry(
            id: panelId,
            workspaceId: workspaceId,
            sessionName: name,
            cmd: "",
            dir: "",
            detachedAt: at
        )
    }
}
