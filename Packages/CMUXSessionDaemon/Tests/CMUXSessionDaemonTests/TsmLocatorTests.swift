import XCTest
@testable import CMUXSessionDaemon

final class TsmLocatorTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tsm-locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testResolvesFromPathEnv() throws {
        let tsm = tempDir.appendingPathComponent("tsm")
        try "#!/bin/sh\necho ok".write(to: tsm, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tsm.path)

        let resolved = TsmLocator.resolveBinary(environment: ["PATH": tempDir.path])
        XCTAssertEqual(resolved?.path, tsm.path)
    }

    func testReturnsNilWhenMissing() {
        let resolved = TsmLocator.resolveBinary(
            environment: ["PATH": tempDir.path],
            useCandidatePaths: false
        )
        XCTAssertNil(resolved)
    }

    func testSessionDirectoryRespectsTSMDIR() {
        let env = ["TSM_DIR": tempDir.path]
        XCTAssertEqual(
            TsmLocator.sessionDirectory(environment: env).path,
            tempDir.appendingPathComponent("sessions").path
        )
    }

    func testSessionDirectoryDefaultsToHome() {
        let env = ["HOME": "/private/var/foo"]
        let result = TsmLocator.sessionDirectory(environment: env).path
        XCTAssertEqual(result, "/private/var/foo/.local/share/tsm/sessions")
    }
}
