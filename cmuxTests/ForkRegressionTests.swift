// Fork-only regression tests. Run after every upstream merge to catch
// silent removal of fork-added behavior.
//
// Coverage:
// 1. SessionTerminalPanelSnapshot.zmx field round-trips through Codable
// 2. HerdrHost.Transport has cmuxTmuxLocal + cmuxTmuxSSH cases
// 3. mainThreadCallableSocketWorkerV2Methods allowlist preserved
// 4. ensure-ghosttykit.sh respects CMUX_GHOSTTYKIT_REPO env var
// 5. CmuxTmuxStdioTransport actor exists and conforms to HerdrTransport
//
// If any of these fail, an upstream merge has clobbered fork-specific
// functionality. Fix the merge resolution, don't disable the test.

import Foundation
import XCTest
@testable import cmux
import CMUXSessionDaemon

final class ForkRegressionTests: XCTestCase {
    // MARK: - 1. zmx field round-trip

    func testForkZmxFieldSurvivesSessionSnapshotRoundTrip() throws {
        let zmx = SessionZmxBindingSnapshot(
            zmxSessionName: "demo",
            originalArgv: ["zmx", "attach", "demo"],
            workingDirectory: "/tmp/work",
            attachState: .attached,
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let snapshot = SessionTerminalPanelSnapshot(
            workingDirectory: "/tmp/work",
            zmx: zmx
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(snapshot)
        let decoded = try decoder.decode(SessionTerminalPanelSnapshot.self, from: data)

        XCTAssertNotNil(decoded.zmx, "zmx field must survive round-trip; upstream merge likely renamed/dropped it")
        XCTAssertEqual(decoded.zmx?.zmxSessionName, "demo")
        XCTAssertEqual(decoded.zmx?.originalArgv, ["zmx", "attach", "demo"])
        XCTAssertEqual(decoded.zmx?.workingDirectory, "/tmp/work")
    }

    func testForkZmxFieldEncodesAsKeyNamedZmx() throws {
        // Older session files key the field exactly as "zmx". If upstream
        // renames it, decoding old user state silently drops the binding.
        let zmx = SessionZmxBindingSnapshot(
            zmxSessionName: "n",
            originalArgv: ["zmx"],
            workingDirectory: "/",
            attachState: .attached,
            lastSeenAt: .init(timeIntervalSince1970: 0)
        )
        let snapshot = SessionTerminalPanelSnapshot(zmx: zmx)
        let data = try JSONEncoder().encode(snapshot)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"zmx\""), "fork-only field must be keyed as 'zmx', got: \(json)")
    }

    // MARK: - 2. Transport enum has cmux-tmux cases

    func testForkTransportEnumHasCmuxTmuxCases() {
        // Compile-time check (file fails to build if cases removed)
        // plus a runtime sanity check.
        let local = HerdrHost.Transport.cmuxTmuxLocal(binaryPath: nil)
        let ssh = HerdrHost.Transport.cmuxTmuxSSH(
            target: "user@host",
            extraArgs: [],
            skipDefaultOptions: false,
            sshExecutable: nil,
            remoteBinaryPath: nil
        )
        switch local {
        case .cmuxTmuxLocal: break
        default: XCTFail("cmuxTmuxLocal case missing or renamed by upstream merge")
        }
        switch ssh {
        case .cmuxTmuxSSH: break
        default: XCTFail("cmuxTmuxSSH case missing or renamed by upstream merge")
        }
    }

    // MARK: - 3. Socket worker main-thread allowlist

    func testForkSocketWorkerAllowlistContainsSystemPing() {
        // mainThreadCallableSocketWorkerV2Methods is private. Probe via
        // the public dispatcher behavior: system.ping must succeed on
        // the main thread without an invalid_dispatch error.
        let payload = "{\"id\":\"t1\",\"method\":\"system.ping\",\"params\":{}}"
        let result = TerminalController.shared.handleSocketLine(payload)
        XCTAssertFalse(
            result.contains("invalid_dispatch"),
            "system.ping must be allowed on main thread; fork allowlist regressed. Got: \(result)"
        )
    }

    // MARK: - 4. ensure-ghosttykit.sh fork-repo override

    func testEnsureGhosttyKitScriptHonorsForkRepoOverride() throws {
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/ensure-ghosttykit.sh")
        let body = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(
            body.contains("CMUX_GHOSTTYKIT_REPO"),
            "ensure-ghosttykit.sh lost the fork-repo override hook (CMUX_GHOSTTYKIT_REPO env var). Local builds without zig will break."
        )
    }

    // MARK: - 5. CmuxTmuxStdioTransport actor

    func testForkCmuxTmuxStdioTransportTypeExists() {
        // If upstream merge removes the type, this test fails to compile.
        let typeName = String(describing: CmuxTmuxStdioTransport.self)
        XCTAssertEqual(typeName, "CmuxTmuxStdioTransport")
    }
}
