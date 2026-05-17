import XCTest
@testable import CMUXZmx

final class ZmxLocatorTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testResolvesFromPathEnv() throws {
        let zmx = tempDir.appendingPathComponent("zmx")
        try "#!/bin/sh\necho ok".write(to: zmx, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zmx.path)

        let resolved = ZmxLocator.resolveBinary(environment: ["PATH": tempDir.path])
        XCTAssertEqual(resolved?.path, zmx.path)
    }

    func testReturnsNilWhenMissing() {
        let resolved = ZmxLocator.resolveBinary(
            environment: ["PATH": tempDir.path],
            useCandidatePaths: false
        )
        XCTAssertNil(resolved)
    }

    func testIsExecutableRejectsDirectory() {
        XCTAssertFalse(ZmxLocator.isExecutable(tempDir))
    }
}
