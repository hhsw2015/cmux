import XCTest
@testable import CMUXZmx

final class SessionZmxBindingSnapshotTests: XCTestCase {
    func testRoundTripPreservesFields() {
        let binding = RestorableZmxBinding(
            workspaceId: UUID(),
            panelId: UUID(),
            zmxSessionName: "work",
            zmxBinaryPath: "/usr/local/bin/zmx",
            originalArgv: ["zmx", "attach", "work"],
            workingDirectory: "/tmp/repo",
            attachState: .attached
        )
        let snap = SessionZmxBindingSnapshot(binding: binding)
        let restored = snap.materialize(
            workspaceId: binding.workspaceId,
            panelId: binding.panelId,
            zmxBinaryPath: binding.zmxBinaryPath
        )
        XCTAssertEqual(restored.zmxSessionName, binding.zmxSessionName)
        XCTAssertEqual(restored.originalArgv, binding.originalArgv)
        XCTAssertEqual(restored.workingDirectory, binding.workingDirectory)
        XCTAssertEqual(restored.attachState, binding.attachState)
    }

    func testCodableRoundTrip() throws {
        let snap = SessionZmxBindingSnapshot(
            zmxSessionName: "logs",
            originalArgv: ["zmx", "a", "logs"],
            workingDirectory: "/var/log",
            attachState: .detached,
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snap)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionZmxBindingSnapshot.self, from: data)
        XCTAssertEqual(decoded, snap)
    }

    func testRestoreUsesCurrentBinaryPath() {
        let snap = SessionZmxBindingSnapshot(
            zmxSessionName: "x",
            originalArgv: ["zmx", "attach", "x"],
            workingDirectory: "/",
            attachState: .attached,
            lastSeenAt: Date()
        )
        let restored = snap.materialize(
            workspaceId: UUID(),
            panelId: UUID(),
            zmxBinaryPath: "/opt/homebrew/bin/zmx"
        )
        XCTAssertEqual(restored.zmxBinaryPath, "/opt/homebrew/bin/zmx")
    }
}
