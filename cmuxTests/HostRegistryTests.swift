import XCTest
@testable import cmux

@MainActor
final class HostRegistryTests: XCTestCase {
    private var tmpURL: URL!

    override func setUp() async throws {
        tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpURL)
    }

    func testLocalhostAlwaysPresentEvenWhenFileEmpty() {
        let registry = HostRegistry(storeURL: tmpURL)
        XCTAssertEqual(registry.hosts.count, 1)
        XCTAssertTrue(registry.hosts[0].isLocalhost)
        XCTAssertEqual(registry.hosts[0].id, HerdrHost.localhostID)
    }

    func testLocalhostCannotBeRemoved() {
        let registry = HostRegistry(storeURL: tmpURL)
        registry.remove(id: HerdrHost.localhostID)
        XCTAssertEqual(registry.hosts.count, 1)
        XCTAssertTrue(registry.hosts[0].isLocalhost)
    }

    func testAddRemoteHostAppendsAndPersists() {
        let registry = HostRegistry(storeURL: tmpURL)
        let host = HerdrHost(
            id: UUID(),
            displayName: "home-server",
            transport: .sshStdio(target: "hs-macaroni"),
            sessionName: "cmux",
            addedAt: Date()
        )
        XCTAssertTrue(registry.add(host))
        XCTAssertEqual(registry.hosts.count, 2)
        XCTAssertEqual(registry.hosts[1].displayName, "home-server")

        let reopened = HostRegistry(storeURL: tmpURL)
        XCTAssertEqual(reopened.hosts.count, 2)
        XCTAssertTrue(reopened.hosts[0].isLocalhost)
        XCTAssertEqual(reopened.hosts[1].displayName, "home-server")
    }

    func testAddRefusesLocalhostShape() {
        let registry = HostRegistry(storeURL: tmpURL)
        let badLocal = HerdrHost(
            id: HerdrHost.localhostID,
            displayName: "bogus",
            transport: .localUDS,
            sessionName: "x",
            addedAt: Date()
        )
        XCTAssertFalse(registry.add(badLocal))
        XCTAssertEqual(registry.hosts.count, 1)
        XCTAssertEqual(registry.hosts[0].displayName, "localhost")
    }

    func testUpdateMutatesExistingEntry() {
        let registry = HostRegistry(storeURL: tmpURL)
        let original = HerdrHost(
            id: UUID(),
            displayName: "orig",
            transport: .sshStdio(target: "old"),
            sessionName: "cmux",
            addedAt: Date()
        )
        XCTAssertTrue(registry.add(original))
        var changed = original
        changed.displayName = "new"
        changed.transport = .sshStdio(target: "newhost")
        registry.update(changed)
        XCTAssertEqual(registry.hosts.count, 2)
        XCTAssertEqual(registry.hosts[1].displayName, "new")
        if case .sshStdio(let target, _, _, _, _) = registry.hosts[1].transport {
            XCTAssertEqual(target, "newhost")
        } else {
            XCTFail("transport not updated")
        }
    }

    func testUpdateLocalhostKeepsTransportAndId() {
        let registry = HostRegistry(storeURL: tmpURL)
        let edited = HerdrHost(
            id: HerdrHost.localhostID,
            displayName: "my mac",
            transport: .sshStdio(target: "should-be-ignored"),
            sessionName: "cmux-renamed",
            addedAt: Date()
        )
        registry.update(edited)
        let local = registry.hosts.first { $0.isLocalhost }!
        XCTAssertEqual(local.id, HerdrHost.localhostID)
        XCTAssertEqual(local.displayName, "my mac")
        XCTAssertEqual(local.sessionName, "cmux-renamed")
        if case .localUDS = local.transport {
            // OK — transport was preserved despite caller passing sshStdio
        } else {
            XCTFail("localhost transport was changed")
        }
    }

    func testRemoveRemoteHostByIdPersists() {
        let registry = HostRegistry(storeURL: tmpURL)
        let host = HerdrHost(
            id: UUID(),
            displayName: "tmp",
            transport: .sshStdio(target: "x"),
            sessionName: "cmux",
            addedAt: Date()
        )
        XCTAssertTrue(registry.add(host))
        XCTAssertEqual(registry.hosts.count, 2)
        registry.remove(id: host.id)
        XCTAssertEqual(registry.hosts.count, 1)

        let reopened = HostRegistry(storeURL: tmpURL)
        XCTAssertEqual(reopened.hosts.count, 1)
    }

    func testCorruptStoreFallsBackToLocalhostOnly() throws {
        try "garbage not json".data(using: .utf8)!.write(to: tmpURL)
        let registry = HostRegistry(storeURL: tmpURL)
        XCTAssertEqual(registry.hosts.count, 1)
        XCTAssertTrue(registry.hosts[0].isLocalhost)
    }

    func testDefaultLocalSessionNameDerivesFromBundle() {
        let name = HerdrHost.defaultLocalSessionName()
        XCTAssertFalse(name.isEmpty)
        XCTAssertTrue(
            name == "cmux" || name == "cmux-dev" || name == "cmux-staging",
            "unexpected default session name: \(name)"
        )
    }
}
