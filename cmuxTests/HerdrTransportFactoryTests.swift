import XCTest
@testable import cmux

final class HerdrTransportFactoryTests: XCTestCase {
    func testLocalUDSHostProducesLocalUDSTransport() {
        let host = HerdrHost.localhost(sessionName: "cmux-test-factory-local")
        let transport = HerdrTransportFactory.make(host: host)
        XCTAssertTrue(transport is LocalUDSTransport)
    }

    func testSSHStdioHostProducesSSHTransport() {
        let host = HerdrHost(
            id: UUID(),
            displayName: "remote",
            transport: .sshStdio(target: "user@remote.example"),
            sessionName: "cmux-test-factory-ssh",
            addedAt: Date()
        )
        let transport = HerdrTransportFactory.make(host: host)
        XCTAssertTrue(transport is SSHStdioTransport)
    }

    func testFactoryReturnsFreshInstancePerCall() {
        let host = HerdrHost.localhost(sessionName: "cmux-test-fresh")
        let a = HerdrTransportFactory.make(host: host)
        let b = HerdrTransportFactory.make(host: host)
        // Each call must allocate a new transport — no caching, since
        // HerdrApiClient takes ownership of the transport actor and
        // calling start() twice on the same instance throws.
        XCTAssertFalse((a as AnyObject) === (b as AnyObject))
    }

    func testLocalApiSocketPathExpandsTilde() {
        let host = HerdrHost.localhost(sessionName: "cmux-tilde-test")
        let path = host.localApiSocketPath
        XCTAssertFalse(path.hasPrefix("~"))
        XCTAssertTrue(path.contains("/.config/herdr/sessions/cmux-tilde-test/herdr.sock"))
    }

    func testLocalApiSocketPathIncludesSessionName() {
        let h1 = HerdrHost.localhost(sessionName: "session-alpha")
        let h2 = HerdrHost.localhost(sessionName: "session-beta")
        XCTAssertNotEqual(h1.localApiSocketPath, h2.localApiSocketPath)
        XCTAssertTrue(h1.localApiSocketPath.contains("session-alpha"))
        XCTAssertTrue(h2.localApiSocketPath.contains("session-beta"))
    }
}
