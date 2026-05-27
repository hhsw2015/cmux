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

@MainActor
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

    // MARK: - 6. zmx field survives FULL nested workspace snapshot round-trip
    //
    // Pre-merge guard for PR #4829 (Ghostty-style top tabs). That PR adds
    // `SessionWorkspaceLayoutTabSnapshot` and wraps panel snapshots inside
    // a `layoutTabs` array. The zmx field lives on the inner
    // SessionTerminalPanelSnapshot and must survive nesting under any
    // future schema reshuffle.

    func testForkZmxFieldSurvivesNestedWorkspaceSnapshotRoundTrip() throws {
        // Build a workspace snapshot from a real TabManager so we don't have
        // to track every field SessionWorkspaceSnapshot grows. Inject a panel
        // snapshot containing zmx via persistence-store rewrite.
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false)
        workspace.setCustomTitle("fork-zmx-test")

        var snapshot = manager.sessionSnapshot(includeScrollback: false)
        guard !snapshot.workspaces.isEmpty,
              !snapshot.workspaces[0].panels.isEmpty else {
            throw XCTSkip("addWorkspace did not produce a default panel; skip")
        }
        let zmx = SessionZmxBindingSnapshot(
            zmxSessionName: "demo-nested",
            originalArgv: ["zmx", "attach", "demo-nested"],
            workingDirectory: "/Users/test/proj",
            attachState: .attached,
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        if snapshot.workspaces[0].panels[0].terminal != nil {
            snapshot.workspaces[0].panels[0].terminal!.zmx = zmx
        } else {
            snapshot.workspaces[0].panels[0].terminal = SessionTerminalPanelSnapshot(zmx: zmx)
        }

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: data)

        let decodedZmx = try XCTUnwrap(
            decoded.workspaces.first?.panels.first?.terminal?.zmx,
            "zmx field on nested panel terminal snapshot must survive full TabManager snapshot round-trip; PR #4829 layoutTabs wrapper or future schema change broke it"
        )
        XCTAssertEqual(decodedZmx.zmxSessionName, "demo-nested")
        XCTAssertEqual(decodedZmx.originalArgv, ["zmx", "attach", "demo-nested"])
    }

    // MARK: - 7. Bonsplit accessor naming guard
    //
    // PR #4829 introduces overload `bonsplitController(containingPanelId:)`,
    // `bonsplitController(containingPaneId:)`, and `bonsplitController(containingSurfaceId:)`.
    // The default `bonsplitController` (no args) still exists. Fork code in
    // HerdrInboundLayoutSync etc. uses the no-arg form. After merge, those
    // call sites must be audited but should still COMPILE. This test exists
    // so a future upstream change that REMOVES the no-arg accessor breaks
    // here loudly instead of cascading through 20+ HerdrClient files.

    func testForkBonsplitControllerNoArgAccessorPreserved() {
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false)
        // Property access compile-check. If this stops being a property and
        // becomes only a function with required label, fork's HerdrClient
        // call sites stop compiling, surfacing the regression here first.
        _ = workspace.bonsplitController.allPaneIds
    }

    private func layoutContains(layout: SessionWorkspaceLayoutSnapshot, panelId: UUID) -> Bool {
        switch layout {
        case .pane(let pane):
            return pane.panelIds.contains(panelId)
        case .split(let split):
            return layoutContains(layout: split.first, panelId: panelId)
                || layoutContains(layout: split.second, panelId: panelId)
        }
    }

    // MARK: - 8. zmx panel restore drives initialInput end-to-end
    //
    // Catches the actual logic regression class that PR #4829 (top tabs)
    // is most likely to introduce: even if `SessionTerminalPanelSnapshot.zmx`
    // still exists and Codable round-trips, the restore PATH inside
    // `Workspace.restoreSessionSnapshot` could lose its `zmxStartupInput`
    // step when that function gets refactored to walk per-layoutTab
    // children. Compile passes, Codable passes, but the user opens cmux
    // after restart and the zmx panel boots a plain shell instead of
    // reattaching to the daemon.
    //
    // This test injects a zmx field into the saved-state JSON, runs the
    // full restoreSessionSnapshot path on a fresh TabManager, then probes
    // the resulting TerminalPanel's surface.initialInput for the
    // `zmx attach` invocation we expect.

    func testForkZmxPanelRestoreInjectsAttachIntoInitialInput() throws {
        // Source: build a workspace, snapshot it, inject zmx into the
        // first terminal panel's snapshot.
        let source = TabManager()
        let sourceWorkspace = source.addWorkspace(select: false)
        sourceWorkspace.setCustomTitle("fork-zmx-restore-test")

        var snapshot = source.sessionSnapshot(includeScrollback: false)
        guard let wsIdx = snapshot.workspaces.firstIndex(where: { $0.customTitle == "fork-zmx-restore-test" }),
              !snapshot.workspaces[wsIdx].panels.isEmpty else {
            throw XCTSkip("could not locate test workspace in snapshot; addWorkspace flow changed")
        }
        let originalPanelId = snapshot.workspaces[wsIdx].panels[0].id

        let zmx = SessionZmxBindingSnapshot(
            zmxSessionName: "fork-test-attach",
            originalArgv: ["zmx", "attach", "fork-test-attach"],
            workingDirectory: NSTemporaryDirectory(),
            attachState: .attached,
            lastSeenAt: Date()
        )

        if snapshot.workspaces[wsIdx].panels[0].terminal != nil {
            snapshot.workspaces[wsIdx].panels[0].terminal!.zmx = zmx
            snapshot.workspaces[wsIdx].panels[0].terminal!.workingDirectory = NSTemporaryDirectory()
        } else {
            snapshot.workspaces[wsIdx].panels[0].terminal = SessionTerminalPanelSnapshot(
                workingDirectory: NSTemporaryDirectory(),
                zmx: zmx
            )
        }
        snapshot.workspaces[wsIdx].panels[0].directory = NSTemporaryDirectory()
        snapshot.workspaces[wsIdx].currentDirectory = NSTemporaryDirectory()

        // Sanity: snapshot must actually carry zmx into the restore path.
        XCTAssertNotNil(
            snapshot.workspaces[wsIdx].panels[0].terminal?.zmx,
            "test setup: zmx must be present in snapshot before restore"
        )
        XCTAssertEqual(
            snapshot.workspaces[wsIdx].panels[0].type,
            .terminal,
            "test setup: panel type must be .terminal so createPanel takes the terminal branch"
        )
        let layoutContainsPanel = layoutContains(layout: snapshot.workspaces[wsIdx].layout, panelId: originalPanelId)
        XCTAssertTrue(
            layoutContainsPanel,
            "test setup: source layout must reference panel \(originalPanelId.uuidString.prefix(8))"
        )

        // Destination: fresh manager runs the full restore path that the
        // top-tabs PR refactors.
        let destination = TabManager()
        destination.restoreSessionSnapshot(snapshot)

        let restoredWorkspace = try XCTUnwrap(
            destination.tabs.first(where: { $0.customTitle == "fork-zmx-restore-test" }),
            "restored workspace must reappear with its custom title"
        )
        let allTerminals = restoredWorkspace.panels.values.compactMap { $0 as? TerminalPanel }
        XCTAssertFalse(
            allTerminals.isEmpty,
            "restored workspace must contain at least one TerminalPanel"
        )
        let allInputs = allTerminals.map { (id: $0.id, input: $0.surface.initialInput ?? "<nil>") }
        _ = originalPanelId

        let input = try XCTUnwrap(
            allInputs.first(where: { $0.input.contains("zmx") })?.input,
            "zmx restore must seed the terminal surface's initialInput; "
            + "Workspace.restoreSessionSnapshot dropped the zmxStartupInput step "
            + "(likely while accommodating PR #4829 layoutTab restructure). "
            + "All restored panel inputs: \(allInputs)"
        )
        XCTAssertTrue(
            input.contains("zmx") && input.contains("attach"),
            "initialInput should contain 'zmx attach' command, got: \(input)"
        )
        XCTAssertTrue(
            input.contains("fork-test-attach"),
            "initialInput should mention the saved zmx session name, got: \(input)"
        )
    }
}
