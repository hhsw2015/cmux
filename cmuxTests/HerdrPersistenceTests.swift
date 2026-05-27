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
        XCTAssertTrue(p.entries(forHostSession: host.sessionName).isEmpty)
        p.record(host: host, workspaceId: "ws1", tabId: "ws1:1", cmuxWorkspaceId: nil)
        let entry = p.entries(forHostSession: host.sessionName).first
        XCTAssertEqual(entry?.workspaceId, "ws1")
        XCTAssertEqual(entry?.tabId, "ws1:1")
    }

    func testFilePersistsAcrossInstances() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let host = HerdrHost.localhost(sessionName: "cmux-test-2")
        do {
            let p = HerdrPersistence(url: url)
            p.record(host: host, workspaceId: "wsA", tabId: "wsA:1", cmuxWorkspaceId: nil)
        }
        // New instance reads the same file.
        let p2 = HerdrPersistence(url: url)
        let entry = p2.entries(forHostSession: host.sessionName).first
        XCTAssertEqual(entry?.workspaceId, "wsA")
        XCTAssertEqual(entry?.tabId, "wsA:1")
    }

    func testClearRemovesEntry() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let p = HerdrPersistence(url: url)
        let host = HerdrHost.localhost(sessionName: "cmux-test-3")
        p.record(host: host, workspaceId: "ws", tabId: "ws:1", cmuxWorkspaceId: nil)
        p.clear(host: host)
        XCTAssertTrue(p.entries(forHostSession: host.sessionName).isEmpty)

        // Clear is idempotent.
        p.clear(host: host)
        XCTAssertTrue(p.entries(forHostSession: host.sessionName).isEmpty)
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
        p.record(host: h1, workspaceId: "wsA", tabId: "wsA:1", cmuxWorkspaceId: nil)
        p.record(host: h2, workspaceId: "wsB", tabId: "wsB:1", cmuxWorkspaceId: nil)
        XCTAssertEqual(p.entries(forHostSession: h1.sessionName).first?.workspaceId, "wsA")
        XCTAssertEqual(p.entries(forHostSession: h2.sessionName).first?.workspaceId, "wsB")

        p.clear(host: h1)
        XCTAssertTrue(p.entries(forHostSession: h1.sessionName).isEmpty)
        XCTAssertEqual(p.entries(forHostSession: h2.sessionName).first?.workspaceId, "wsB")
    }

    func testRecordUpdatesEntryOnSameWorkspaceAndTab() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let p = HerdrPersistence(url: url)
        let host = HerdrHost.localhost(sessionName: "cmux-update")
        let cmuxA = UUID()
        let cmuxB = UUID()
        p.record(host: host, workspaceId: "ws1", tabId: "ws1:1", cmuxWorkspaceId: cmuxA)
        p.record(host: host, workspaceId: "ws1", tabId: "ws1:1", cmuxWorkspaceId: cmuxB)
        let entries = p.entries(forHostSession: host.sessionName)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.cmuxWorkspaceId, cmuxB)
    }

    func testRecordAppendsEntryForDifferentWorkspaceOrTab() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let p = HerdrPersistence(url: url)
        let host = HerdrHost.localhost(sessionName: "cmux-append")
        p.record(host: host, workspaceId: "ws1", tabId: "ws1:1", cmuxWorkspaceId: nil)
        p.record(host: host, workspaceId: "ws2", tabId: "ws2:7", cmuxWorkspaceId: nil)
        let entries = p.entries(forHostSession: host.sessionName)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.workspaceId), ["ws1", "ws2"])
    }
}
