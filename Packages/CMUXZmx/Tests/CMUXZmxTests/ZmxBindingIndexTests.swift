import XCTest
@testable import CMUXZmx

final class ZmxBindingIndexTests: XCTestCase {
    private var tempDir: URL!
    private var storeURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-zmx-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("bindings.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testUpsertAndLookup() async {
        let index = ZmxBindingIndex(storeURL: storeURL)
        let binding = makeBinding(name: "work")
        await index.upsert(binding)
        let found = await index.lookup(panelId: binding.panelId)
        XCTAssertEqual(found?.zmxSessionName, "work")
    }

    func testRemove() async {
        let index = ZmxBindingIndex(storeURL: storeURL)
        let binding = makeBinding(name: "work")
        await index.upsert(binding)
        await index.remove(panelId: binding.panelId)
        let found = await index.lookup(panelId: binding.panelId)
        XCTAssertNil(found)
    }

    func testPersistsAcrossInstances() async {
        let workspaceId = UUID()
        let panelId = UUID()
        let first = ZmxBindingIndex(storeURL: storeURL)
        let binding = makeBinding(workspaceId: workspaceId, panelId: panelId, name: "logs")
        await first.upsert(binding)

        let second = ZmxBindingIndex(storeURL: storeURL)
        let found = await second.lookup(panelId: panelId)
        XCTAssertEqual(found?.zmxSessionName, "logs")
        XCTAssertEqual(found?.workspaceId, workspaceId)
    }

    func testReconcileMarksMissingSessionsLost() async {
        let index = ZmxBindingIndex(storeURL: storeURL)
        let binding = makeBinding(name: "ghost")
        await index.upsert(binding)
        let lost = await index.reconcile(aliveSessions: [])
        XCTAssertEqual(lost.count, 1)
        let found = await index.lookup(panelId: binding.panelId)
        XCTAssertEqual(found?.attachState, .lost)
    }

    func testReconcileLeavesAliveSessionsUntouched() async {
        let index = ZmxBindingIndex(storeURL: storeURL)
        let binding = makeBinding(name: "alive")
        await index.upsert(binding)
        let lost = await index.reconcile(aliveSessions: ["alive"])
        XCTAssertTrue(lost.isEmpty)
        let found = await index.lookup(panelId: binding.panelId)
        XCTAssertEqual(found?.attachState, .attached)
    }

    func testPurgeBySessionNameRemovesEveryMatch() async {
        let index = ZmxBindingIndex(storeURL: storeURL)
        let workspaceA = UUID()
        let workspaceB = UUID()
        // Two panels in different workspaces both attached to "shared"
        await index.upsert(makeBinding(workspaceId: workspaceA, name: "shared"))
        await index.upsert(makeBinding(workspaceId: workspaceB, name: "shared"))
        // Plus an unrelated binding
        let other = makeBinding(name: "other")
        await index.upsert(other)

        let removed = await index.purge(sessionName: "shared")
        XCTAssertEqual(removed, 2)
        let remaining = await index.all()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.zmxSessionName, "other")
    }

    func testPurgeBySessionNameNoMatchReturnsZero() async {
        let index = ZmxBindingIndex(storeURL: storeURL)
        await index.upsert(makeBinding(name: "alpha"))
        let removed = await index.purge(sessionName: "missing")
        XCTAssertEqual(removed, 0)
    }

    func testCorruptFileBackedUpAndCleared() async {
        try? "{ this is not json".write(to: storeURL, atomically: true, encoding: .utf8)
        let index = ZmxBindingIndex(storeURL: storeURL)
        let all = await index.all()
        XCTAssertTrue(all.isEmpty)

        let backups = (try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(backups.contains(where: { $0.lastPathComponent.hasPrefix("zmx-bindings.corrupt-") }))
    }

    private func makeBinding(
        workspaceId: UUID = UUID(),
        panelId: UUID = UUID(),
        name: String
    ) -> RestorableZmxBinding {
        RestorableZmxBinding(
            workspaceId: workspaceId,
            panelId: panelId,
            zmxSessionName: name,
            zmxBinaryPath: "/usr/local/bin/zmx",
            originalArgv: ["zmx", "attach", name],
            workingDirectory: "/tmp"
        )
    }
}
