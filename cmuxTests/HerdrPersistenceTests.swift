import XCTest
@testable import cmux

@MainActor
final class HerdrPersistenceTests: XCTestCase {
    private func makeTempURL() -> URL {
        let temp = FileManager.default.temporaryDirectory
        return temp.appendingPathComponent(
            "herdr-persistence-test-\(UUID().uuidString).json"
        )
    }

    func testRecordAndEntryRoundTrip() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let p = HerdrPersistence(url: url)
        let host = HerdrHost.localhost(sessionName: "cmux-test-1")
        XCTAssertNil(p.entry(forHostSession: host.sessionName))
        p.record(host: host, workspaceId: "ws1", tabId: "ws1:1")
        let entry = p.entry(forHostSession: host.sessionName)
        XCTAssertEqual(entry?.workspaceId, "ws1")
        XCTAssertEqual(entry?.tabId, "ws1:1")
    }

    func testFilePersistsAcrossInstances() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let host = HerdrHost.localhost(sessionName: "cmux-test-2")
        do {
            let p = HerdrPersistence(url: url)
            p.record(host: host, workspaceId: "wsA", tabId: "wsA:1")
        }
        // New instance reads the same file.
        let p2 = HerdrPersistence(url: url)
        let entry = p2.entry(forHostSession: host.sessionName)
        XCTAssertEqual(entry?.workspaceId, "wsA")
        XCTAssertEqual(entry?.tabId, "wsA:1")
    }

    func testClearRemovesEntry() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let p = HerdrPersistence(url: url)
        let host = HerdrHost.localhost(sessionName: "cmux-test-3")
        p.record(host: host, workspaceId: "ws", tabId: "ws:1")
        p.clear(host: host)
        XCTAssertNil(p.entry(forHostSession: host.sessionName))

        // Clear is idempotent.
        p.clear(host: host)
        XCTAssertNil(p.entry(forHostSession: host.sessionName))
    }

    func testMultipleHostsCoexist() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let p = HerdrPersistence(url: url)
        let h1 = HerdrHost.localhost(sessionName: "cmux-A")
        let h2 = HerdrHost(
            id: UUID(),
            displayName: "remote",
            transport: .sshStdio(target: "user@remote"),
            sessionName: "cmux-B",
            addedAt: Date()
        )
        p.record(host: h1, workspaceId: "wsA", tabId: "wsA:1")
        p.record(host: h2, workspaceId: "wsB", tabId: "wsB:1")
        XCTAssertEqual(p.entry(forHostSession: h1.sessionName)?.workspaceId, "wsA")
        XCTAssertEqual(p.entry(forHostSession: h2.sessionName)?.workspaceId, "wsB")

        p.clear(host: h1)
        XCTAssertNil(p.entry(forHostSession: h1.sessionName))
        XCTAssertEqual(p.entry(forHostSession: h2.sessionName)?.workspaceId, "wsB")
    }

    func testRecordOverwritesPreviousEntry() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let p = HerdrPersistence(url: url)
        let host = HerdrHost.localhost(sessionName: "cmux-overwrite")
        p.record(host: host, workspaceId: "ws1", tabId: "ws1:1")
        p.record(host: host, workspaceId: "ws2", tabId: "ws2:7")
        let entry = p.entry(forHostSession: host.sessionName)
        XCTAssertEqual(entry?.workspaceId, "ws2")
        XCTAssertEqual(entry?.tabId, "ws2:7")
    }
}
