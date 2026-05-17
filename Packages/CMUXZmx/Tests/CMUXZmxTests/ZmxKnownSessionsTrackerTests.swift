import XCTest
@testable import CMUXZmx

final class ZmxKnownSessionsTrackerTests: XCTestCase {
    private var tempDir: URL!
    private var storeURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-known-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("known.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRecordInsertsNewSessions() async {
        let tracker = ZmxKnownSessionsTracker(storeURL: storeURL)
        await tracker.record(live: [
            ZmxSystemScanner.LiveAttach(pid: 1, parentPid: 0, sessionName: "work", argv: ["zmx", "a", "work"]),
            ZmxSystemScanner.LiveAttach(pid: 2, parentPid: 0, sessionName: "logs", argv: ["zmx", "a", "logs"])
        ])
        let all = await tracker.all()
        XCTAssertEqual(Set(all.map(\.sessionName)), ["work", "logs"])
    }

    func testRecordUpdatesLastSeen() async {
        let tracker = ZmxKnownSessionsTracker(storeURL: storeURL)
        await tracker.record(live: [
            ZmxSystemScanner.LiveAttach(pid: 1, parentPid: 0, sessionName: "work", argv: ["zmx", "a", "work"])
        ])
        let firstSnapshot = await tracker.all().first!
        try? await Task.sleep(nanoseconds: 50_000_000)
        await tracker.record(live: [
            ZmxSystemScanner.LiveAttach(pid: 99, parentPid: 0, sessionName: "work", argv: ["zmx", "a", "work"])
        ])
        let secondSnapshot = await tracker.all().first!
        XCTAssertEqual(firstSnapshot.firstSeenAt, secondSnapshot.firstSeenAt)
        XCTAssertGreaterThan(secondSnapshot.lastSeenAt, firstSnapshot.lastSeenAt)
    }

    func testReconcileDropsMissingSessions() async {
        let tracker = ZmxKnownSessionsTracker(storeURL: storeURL)
        await tracker.record(live: [
            ZmxSystemScanner.LiveAttach(pid: 1, parentPid: 0, sessionName: "alpha", argv: ["zmx", "a", "alpha"]),
            ZmxSystemScanner.LiveAttach(pid: 2, parentPid: 0, sessionName: "beta", argv: ["zmx", "a", "beta"])
        ])
        let stale = await tracker.reconcile(aliveSessions: ["alpha"])
        XCTAssertEqual(stale.map(\.sessionName), ["beta"])
        let remaining = await tracker.all()
        XCTAssertEqual(remaining.map(\.sessionName), ["alpha"])
    }

    func testPersistsAcrossInstances() async {
        let first = ZmxKnownSessionsTracker(storeURL: storeURL)
        await first.record(live: [
            ZmxSystemScanner.LiveAttach(pid: 1, parentPid: 0, sessionName: "work", argv: ["zmx", "a", "work"])
        ])
        let second = ZmxKnownSessionsTracker(storeURL: storeURL)
        let all = await second.all()
        XCTAssertEqual(all.map(\.sessionName), ["work"])
    }
}
