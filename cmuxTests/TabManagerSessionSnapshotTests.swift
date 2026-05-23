import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TabManagerSessionSnapshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ClosedItemHistoryStore.shared.removeAll()
    }

    override func tearDown() {
        ClosedItemHistoryStore.shared.removeAll()
        super.tearDown()
    }

    func testSessionSnapshotSerializesWorkspacesAndRestoreRebuildsSelection() {
        let manager = TabManager()
        guard let firstWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected initial workspace")
            return
        }
        firstWorkspace.setCustomTitle("First")

        let secondWorkspace = manager.addWorkspace(select: true)
        secondWorkspace.setCustomTitle("Second")
        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(snapshot.workspaces.count, 2)
        XCTAssertEqual(snapshot.selectedWorkspaceIndex, 1)

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertEqual(restored.selectedTabId, restored.tabs[1].id)
        XCTAssertEqual(restored.tabs[0].customTitle, "First")
        XCTAssertEqual(restored.tabs[1].customTitle, "Second")
    }

    func testFocusHistoryNavigatesWithinWorkspacePanels() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let secondPanelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        workspace.focusPanel(firstPanelId)
        workspace.focusPanel(secondPanelId)

        XCTAssertTrue(manager.canNavigateBack)

        manager.navigateBack()

        XCTAssertEqual(workspace.focusedPanelId, firstPanelId)
        XCTAssertTrue(manager.canNavigateForward)
    }

    func testFocusHistoryBackFallsBackWhenRecordedPanelWasClosed() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(firstWorkspace.bonsplitController.allPaneIds.first)
        let closedPanelId = try XCTUnwrap(firstWorkspace.focusedPanelId)
        let fallbackPanelId = try XCTUnwrap(firstWorkspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        firstWorkspace.focusPanel(closedPanelId)
        let secondWorkspace = manager.addWorkspace(select: true)
        _ = firstWorkspace.closePanel(closedPanelId, force: true)

        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
        XCTAssertTrue(manager.canNavigateBack)

        manager.navigateBack()

        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertEqual(firstWorkspace.focusedPanelId, fallbackPanelId)
        XCTAssertNil(firstWorkspace.panels[closedPanelId])
    }

    func testFocusHistoryBackSkipsStaleEntriesThatResolveToCurrentPanel() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let closedPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let fallbackPanelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        workspace.focusPanel(closedPanelId)
        _ = workspace.closePanel(closedPanelId, force: true)
        drainMainQueue()

        XCTAssertEqual(workspace.focusedPanelId, fallbackPanelId)
        XCTAssertFalse(manager.canNavigateBack)

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .tabManagerFocusHistoryRevisionDidChange,
            object: manager,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        manager.navigateBack()

        XCTAssertEqual(workspace.focusedPanelId, fallbackPanelId)
        XCTAssertEqual(notificationCount, 0)
    }

    func testGhosttyFocusSurfaceIdRecordsMappedPanelInFocusHistory() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let secondPanelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)
        let secondSurfaceId = try XCTUnwrap(workspace.surfaceIdFromPanelId(secondPanelId))
        XCTAssertNotEqual(secondSurfaceId.uuid, secondPanelId)

        let firstPanelId = try XCTUnwrap(workspace.panels.keys.first { $0 != secondPanelId })
        workspace.focusPanel(firstPanelId)
        let revision = manager.focusHistoryRevision

        NotificationCenter.default.post(
            name: .ghosttyDidFocusSurface,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: secondSurfaceId.uuid,
            ]
        )
        drainMainQueue()

        XCTAssertGreaterThan(manager.focusHistoryRevision, revision)
    }

    func testFocusHistoryNavigatesBetweenFreshWorkspaces() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let secondWorkspace = manager.addWorkspace(select: true)

        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
        XCTAssertTrue(manager.canNavigateBack)

        manager.navigateBack()

        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertTrue(manager.canNavigateForward)
        NotificationCenter.default.post(
            name: .ghosttyDidFocusSurface,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: firstWorkspace.id,
                GhosttyNotificationKey.surfaceId: try XCTUnwrap(firstWorkspace.focusedPanelId),
            ]
        )
        drainMainQueue()
        XCTAssertTrue(manager.canNavigateForward)

        manager.navigateForward()

        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
    }

    func testFocusHistoryRevisionPostsMenuInvalidationNotification() {
        let manager = TabManager()
        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .tabManagerFocusHistoryRevisionDidChange,
            object: manager,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        _ = manager.addWorkspace(select: true)

        XCTAssertGreaterThan(notificationCount, 0)
    }

    func testFocusHistoryNavigationNotificationSeesUpdatedDirectionState() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let secondWorkspace = manager.addWorkspace(select: true)
        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
        XCTAssertTrue(manager.canNavigateBack)

        var observedCanNavigateForward = false
        let observer = NotificationCenter.default.addObserver(
            forName: .tabManagerFocusHistoryRevisionDidChange,
            object: manager,
            queue: nil
        ) { _ in
            observedCanNavigateForward = manager.canNavigateForward
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        manager.navigateBack()

        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertTrue(observedCanNavigateForward)
    }

    func testReopenClosedItemRestoresClosedPanelSnapshot() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        workspace.markCloseHistoryEligible(panelId: panelId)
        XCTAssertTrue(workspace.closePanel(panelId, force: true))
        drainMainQueue()
        XCTAssertNil(workspace.panels[panelId])
        XCTAssertTrue(ClosedItemHistoryStore.shared.canReopen)

        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        XCTAssertEqual(workspace.panels.count, 2)
        XCTAssertNotNil(workspace.focusedPanelId.flatMap { workspace.panels[$0] })
    }

    func testReopenClosedPanelBackReturnsToPreviousWorkspaceFocus() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let secondWorkspace = manager.addWorkspace(select: false)
        let pane = try XCTUnwrap(secondWorkspace.bonsplitController.allPaneIds.first)
        let panelId = try XCTUnwrap(secondWorkspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        secondWorkspace.markCloseHistoryEligible(panelId: panelId)
        XCTAssertTrue(secondWorkspace.closePanel(panelId, force: true))
        drainMainQueue()

        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
        XCTAssertTrue(manager.canNavigateBack)

        manager.navigateBack()

        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
    }

    func testReopenClosedPanelPreservesForwardFocusHistoryBranch() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let secondWorkspace = manager.addWorkspace(select: true)

        manager.navigateBack()

        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertTrue(manager.canNavigateForward)

        let pane = try XCTUnwrap(firstWorkspace.bonsplitController.allPaneIds.first)
        let panelId = try XCTUnwrap(firstWorkspace.newTerminalSurface(inPane: pane, focus: false)?.id)

        firstWorkspace.markCloseHistoryEligible(panelId: panelId)
        XCTAssertTrue(firstWorkspace.closePanel(panelId, force: true))
        drainMainQueue()

        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        XCTAssertTrue(manager.canNavigateForward)

        manager.navigateForward()

        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
    }

    func testReopenClosedItemRestoresClosedWorkspaceSnapshot() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let secondWorkspace = manager.addWorkspace(select: true)
        secondWorkspace.setCustomTitle("Recovered")

        manager.closeWorkspace(secondWorkspace)

        XCTAssertEqual(manager.tabs.map(\.id), [firstWorkspace.id])
        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertEqual(manager.selectedWorkspace?.customTitle, "Recovered")
    }

    func testReopenClosedWorkspaceBackReturnsToPreviousWorkspaceFocus() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let secondWorkspace = manager.addWorkspace(select: true)
        secondWorkspace.setCustomTitle("Recovered")

        manager.closeWorkspace(secondWorkspace)

        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        XCTAssertEqual(manager.selectedWorkspace?.customTitle, "Recovered")
        XCTAssertTrue(manager.canNavigateBack)

        manager.navigateBack()

        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
    }

    func testReopenClosedWindowWithoutAppDelegatePreservesHistoryEntry() throws {
        let originalAppDelegate = AppDelegate.shared
        AppDelegate.shared = nil
        defer {
            AppDelegate.shared = originalAppDelegate
        }

        let manager = TabManager()
        let snapshot = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: manager.sessionSnapshot(includeScrollback: false),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
        )
        ClosedItemHistoryStore.shared.push(.window(ClosedWindowHistoryEntry(snapshot: snapshot)))

        XCTAssertFalse(manager.reopenMostRecentlyClosedItem())
        XCTAssertTrue(ClosedItemHistoryStore.shared.canReopen)
        XCTAssertEqual(ClosedItemHistoryStore.shared.entries.count, 1)
        guard case .window = ClosedItemHistoryStore.shared.entries.last else {
            XCTFail("Expected closed window history to remain queued")
            return
        }
    }

    func testRestoreSessionSnapshotWithNoWorkspacesKeepsSingleFallbackWorkspace() {
        let manager = TabManager()
        let emptySnapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: nil,
            workspaces: []
        )

        manager.restoreSessionSnapshot(emptySnapshot)

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertNotNil(manager.selectedTabId)
    }

    func testRestoredPersistentSSHBrowserOnlyWorkspaceAutoConnectsWithoutForegroundAuthTerminal() {
        let browserPanelId = UUID()
        let browserOnlySnapshot = Self.persistentSSHWorkspaceSnapshot(
            panel: Self.browserPanelSnapshot(id: browserPanelId),
            focusedPanelId: browserPanelId
        )
        XCTAssertTrue(Workspace.shouldAutoConnectRestoredRemote(
            foregroundAuthToken: " token-a ",
            snapshot: browserOnlySnapshot,
            isRunningUnderAutomatedTests: false
        ))

        let terminalPanelId = UUID()
        let terminalSnapshot = Self.persistentSSHWorkspaceSnapshot(
            panel: Self.terminalPanelSnapshot(id: terminalPanelId),
            focusedPanelId: terminalPanelId
        )
        XCTAssertFalse(Workspace.shouldAutoConnectRestoredRemote(
            foregroundAuthToken: "token-a",
            snapshot: terminalSnapshot,
            isRunningUnderAutomatedTests: false
        ))
        XCTAssertTrue(Workspace.shouldAutoConnectRestoredRemote(
            foregroundAuthToken: nil,
            snapshot: terminalSnapshot,
            isRunningUnderAutomatedTests: false
        ))
        XCTAssertFalse(Workspace.shouldAutoConnectRestoredRemote(
            foregroundAuthToken: nil,
            snapshot: browserOnlySnapshot,
            isRunningUnderAutomatedTests: true
        ))
    }

    func testSessionSnapshotIncludesRemoteWorkspacesForRestore() throws {
        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64001,
            relayID: "relay-test",
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        let paneId = try XCTUnwrap(remoteWorkspace.bonsplitController.allPaneIds.first)
        _ = remoteWorkspace.newBrowserSurface(inPane: paneId, url: URL(string: "http://localhost:3000"), focus: false)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)

        XCTAssertEqual(snapshot.workspaces.count, 2)
        XCTAssertEqual(snapshot.selectedWorkspaceIndex, 1)
        let remoteSnapshot = try XCTUnwrap(snapshot.workspaces.first { $0.processTitle == remoteWorkspace.title })
        XCTAssertEqual(remoteSnapshot.remote?.destination, "cmux-macmini")
    }

    func testSessionSnapshotSkipsNonRestorableRemoteWorkspaces() {
        let manager = TabManager()
        let localWorkspace = manager.tabs[0]
        localWorkspace.setCustomTitle("Local")
        let remoteWorkspace = manager.addWorkspace(select: true)
        remoteWorkspace.setCustomTitle("Cloud VM")
        let configuration = WorkspaceRemoteConfiguration(
            transport: .websocket,
            destination: "cloud-vm",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: 54321,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)

        XCTAssertEqual(snapshot.workspaces.count, 1)
        XCTAssertEqual(snapshot.workspaces.first?.customTitle, "Local")
        XCTAssertNil(snapshot.workspaces.first?.remote)
        XCTAssertNil(snapshot.selectedWorkspaceIndex)
    }

    func testRestoringLocalWorkspaceSnapshotClearsStaleRemoteState() throws {
        let localSnapshot = try XCTUnwrap(TabManager().selectedWorkspace)
            .sessionSnapshot(includeScrollback: false)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64001,
            relayID: "relay-test",
            relayToken: String(repeating: "c", count: 64),
            localSocketPath: "/tmp/cmux-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        XCTAssertTrue(workspace.isRemoteWorkspace)

        workspace.restoreSessionSnapshot(localSnapshot)

        XCTAssertFalse(workspace.isRemoteWorkspace)
        XCTAssertNil(workspace.remoteConfiguration)
        XCTAssertFalse(workspace.hasActiveRemoteTerminalSessions)
    }

    func testSessionSnapshotRestoresSSHWorkspaceDescriptor() throws {
        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        remoteWorkspace.setCustomTitle("Remote Mac mini")
        let identityFile = "~/.ssh/id_ed25519"
        let expandedIdentityFile = (identityFile as NSString).expandingTildeInPath
        let configuration = WorkspaceRemoteConfiguration(
            destination: "dev@example.com",
            port: 2222,
            identityFile: identityFile,
            sshOptions: [
                "ControlPath=/tmp/cmux-ssh-%C",
                "ControlMaster=auto",
                "ControlPersist=60s",
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64002,
            relayID: "relay-restore-test",
            relayToken: String(repeating: "d", count: 64),
            localSocketPath: "/tmp/cmux-restore-test.sock",
            terminalStartupCommand: "ssh dev@example.com"
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        let remotePanelId = try XCTUnwrap(remoteWorkspace.focusedPanelId)
        remoteWorkspace.updatePanelDirectory(panelId: remotePanelId, directory: "/home/dev/project")

        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-session-restore-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: snapshotURL) }
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: Date().timeIntervalSince1970,
            windows: [
                SessionWindowSnapshot(
                    frame: nil,
                    display: nil,
                    tabManager: manager.sessionSnapshot(includeScrollback: false),
                    sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
                ),
            ]
        )
        XCTAssertTrue(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))
        let persistedTabManager = try XCTUnwrap(
            SessionPersistenceStore.load(fileURL: snapshotURL)?.windows.first?.tabManager
        )
        let remoteSnapshot = try XCTUnwrap(
            persistedTabManager.workspaces.first { $0.customTitle == "Remote Mac mini" }?.remote
        )
        XCTAssertEqual(remoteSnapshot.destination, "dev@example.com")
        XCTAssertEqual(remoteSnapshot.port, 2222)
        XCTAssertEqual(remoteSnapshot.identityFile, expandedIdentityFile)
        XCTAssertEqual(remoteSnapshot.sshOptions, [
            "StrictHostKeyChecking=accept-new",
        ])

        let restored = TabManager()
        restored.restoreSessionSnapshot(persistedTabManager)

        let restoredWorkspace = try XCTUnwrap(
            restored.tabs.first { $0.customTitle == "Remote Mac mini" }
        )
        XCTAssertTrue(restoredWorkspace.isRemoteWorkspace)
        XCTAssertEqual(restoredWorkspace.remoteDisplayTarget, "dev@example.com:2222")
        XCTAssertTrue(restoredWorkspace.hasActiveRemoteTerminalSessions)
        let restoredPanelId = try XCTUnwrap(restoredWorkspace.focusedPanelId)
        XCTAssertEqual(restoredWorkspace.panelDirectories[restoredPanelId], "/home/dev/project")
        XCTAssertNil(restoredWorkspace.terminalPanel(for: restoredPanelId)?.requestedWorkingDirectory)
        XCTAssertEqual(
            restoredWorkspace.remoteConfiguration?.terminalStartupCommand,
            "ssh -p 2222 -i \(expandedIdentityFile) -o StrictHostKeyChecking=accept-new -tt dev@example.com"
        )
    }

    func testSessionSnapshotRestoresPersistentSSHPTYWithFreshAttachAfterRelaunch() throws {
        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        remoteWorkspace.setCustomTitle("Persistent SSH")
        let configuration = WorkspaceRemoteConfiguration(
            destination: "dev@example.com",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64003,
            relayID: "relay-persist-test",
            relayToken: String(repeating: "e", count: 64),
            localSocketPath: "/tmp/cmux-persist-test.sock",
            terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(),
            preserveAfterTerminalExit: true
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        let remotePanelId = try XCTUnwrap(remoteWorkspace.focusedPanelId)
        let expectedSessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: remoteWorkspace.id,
            panelId: remotePanelId
        )
        let seededScrollback = remoteWorkspace.debugSeedSessionSnapshotScrollback(charactersPerTerminal: 160)
        XCTAssertEqual(seededScrollback.terminals, 1)

        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-pty-session-restore-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: snapshotURL) }
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: Date().timeIntervalSince1970,
            windows: [
                SessionWindowSnapshot(
                    frame: nil,
                    display: nil,
                    tabManager: manager.sessionSnapshot(includeScrollback: true),
                    sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
                ),
            ]
        )
        XCTAssertTrue(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))
        let persistedTabManager = try XCTUnwrap(
            SessionPersistenceStore.load(fileURL: snapshotURL)?.windows.first?.tabManager
        )
        let persistedWorkspace = try XCTUnwrap(
            persistedTabManager.workspaces.first { $0.customTitle == "Persistent SSH" }
        )
        XCTAssertEqual(persistedWorkspace.remote?.preserveAfterTerminalExit, true)
        XCTAssertEqual(
            persistedWorkspace.panels.first { $0.id == remotePanelId }?.terminal?.remotePTYSessionID,
            expectedSessionID
        )
        let expectedScrollback = try XCTUnwrap(
            persistedWorkspace.panels.first { $0.id == remotePanelId }?.terminal?.scrollback
        )
        XCTAssertTrue(expectedScrollback.contains("cmux perf synthetic scrollback"), expectedScrollback)

        let restored = TabManager()
        restored.restoreSessionSnapshot(persistedTabManager)

        let restoredWorkspace = try XCTUnwrap(restored.tabs.first { $0.customTitle == "Persistent SSH" })
        XCTAssertEqual(restoredWorkspace.remoteConfiguration?.preserveAfterTerminalExit, true)
        let restoredForegroundAuthToken = try XCTUnwrap(restoredWorkspace.remoteConfiguration?.foregroundAuthToken)
        XCTAssertFalse(restoredForegroundAuthToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let terminalStartupCommand = try XCTUnwrap(restoredWorkspace.remoteConfiguration?.terminalStartupCommand)
        XCTAssertTrue(terminalStartupCommand.contains("ssh-pty-attach"), terminalStartupCommand)
        XCTAssertTrue(terminalStartupCommand.contains("workspace.remote.foreground_auth_ready"), terminalStartupCommand)
        XCTAssertTrue(terminalStartupCommand.contains(restoredForegroundAuthToken), terminalStartupCommand)
        XCTAssertFalse(terminalStartupCommand.contains("--require-existing"), terminalStartupCommand)
        XCTAssertTrue(terminalStartupCommand.contains("254|255"), terminalStartupCommand)
        let restoredPanelId = try XCTUnwrap(restoredWorkspace.focusedPanelId)
        let restoredInitialCommand = try XCTUnwrap(
            restoredWorkspace.terminalPanel(for: restoredPanelId)?.surface.debugInitialCommand()
        )
        XCTAssertTrue(restoredInitialCommand.contains("ssh-pty-attach"), restoredInitialCommand)
        XCTAssertTrue(restoredInitialCommand.contains("workspace.remote.foreground_auth_ready"), restoredInitialCommand)
        XCTAssertTrue(restoredInitialCommand.contains(restoredForegroundAuthToken), restoredInitialCommand)
        XCTAssertFalse(restoredInitialCommand.contains("--require-existing"), restoredInitialCommand)
        XCTAssertTrue(restoredInitialCommand.contains("254|255"), restoredInitialCommand)
        XCTAssertFalse(restoredInitialCommand.contains(expectedSessionID), restoredInitialCommand)
        XCTAssertTrue(restoredInitialCommand.contains("CMUX_SURFACE_ID"), restoredInitialCommand)

        let roundTrip = restoredWorkspace.sessionSnapshot(includeScrollback: false)
        let restoredSessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: restoredWorkspace.id,
            panelId: restoredPanelId
        )
        XCTAssertEqual(roundTrip.remote?.preserveAfterTerminalExit, true)
        XCTAssertEqual(roundTrip.panels.first?.terminal?.remotePTYSessionID, restoredSessionID)
        XCTAssertNotEqual(restoredSessionID, expectedSessionID)
        XCTAssertEqual(
            persistedWorkspace.panels.first { $0.id == remotePanelId }?.terminal?.scrollback,
            expectedScrollback
        )
    }

    func testSessionSnapshotFallsBackFromSkipBootstrapPersistentSSHPTYWithoutDaemonBridge() throws {
        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        remoteWorkspace.setCustomTitle("Durable Persistent SSH")
        let configuration = WorkspaceRemoteConfiguration(
            destination: "dev@example.com",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64003,
            relayID: "relay-persist-test",
            relayToken: String(repeating: "e", count: 64),
            localSocketPath: "/tmp/cmux-persist-test.sock",
            terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(),
            preserveAfterTerminalExit: true,
            skipDaemonBootstrap: true
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        let remotePanelId = try XCTUnwrap(remoteWorkspace.focusedPanelId)
        let expectedSessionID = Workspace.defaultSSHPTYSessionID(workspaceId: remoteWorkspace.id, panelId: remotePanelId)

        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-pty-durable-restore-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: snapshotURL) }
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: Date().timeIntervalSince1970,
            windows: [
                SessionWindowSnapshot(
                    frame: nil,
                    display: nil,
                    tabManager: manager.sessionSnapshot(includeScrollback: true),
                    sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
                ),
            ]
        )
        XCTAssertTrue(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))
        let persistedTabManager = try XCTUnwrap(
            SessionPersistenceStore.load(fileURL: snapshotURL)?.windows.first?.tabManager
        )

        let restored = TabManager()
        restored.restoreSessionSnapshot(persistedTabManager)

        let restoredWorkspace = try XCTUnwrap(restored.tabs.first { $0.customTitle == "Durable Persistent SSH" })
        XCTAssertEqual(restoredWorkspace.remoteConfiguration?.preserveAfterTerminalExit, false)
        XCTAssertNil(restoredWorkspace.remoteConfiguration?.foregroundAuthToken)
        XCTAssertFalse(restoredWorkspace.remoteConfiguration?.sshOptions.contains { $0.hasPrefix("ControlPath") } == true)
        let terminalStartupCommand = try XCTUnwrap(restoredWorkspace.remoteConfiguration?.terminalStartupCommand)
        XCTAssertFalse(terminalStartupCommand.contains("ssh-pty-attach"), terminalStartupCommand)
        XCTAssertFalse(terminalStartupCommand.contains("workspace.remote.foreground_auth_ready"), terminalStartupCommand)
        XCTAssertEqual(terminalStartupCommand, "ssh -p 2222 -o StrictHostKeyChecking=accept-new -tt dev@example.com")

        let restoredPanelId = try XCTUnwrap(restoredWorkspace.focusedPanelId)
        let restoredInitialCommand = try XCTUnwrap(
            restoredWorkspace.terminalPanel(for: restoredPanelId)?.surface.debugInitialCommand()
        )
        XCTAssertFalse(restoredInitialCommand.contains("ssh-pty-attach"), restoredInitialCommand)
        XCTAssertFalse(restoredInitialCommand.contains(expectedSessionID), restoredInitialCommand)
        XCTAssertEqual(restoredInitialCommand, terminalStartupCommand)

        let roundTrip = restoredWorkspace.sessionSnapshot(includeScrollback: false)
        XCTAssertNil(roundTrip.remote?.preserveAfterTerminalExit)
        XCTAssertNil(roundTrip.panels.first?.terminal?.remotePTYSessionID)
    }

    func testSessionRemoteWorkspaceSnapshotDropsInvalidSSHPortFromReconnectCommand() throws {
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            destination: "dev@example.com",
            port: 99_999,
            identityFile: nil,
            sshOptions: [],
            preserveAfterTerminalExit: nil,
            skipDaemonBootstrap: nil
        )

        let configuration = try XCTUnwrap(snapshot.workspaceConfiguration())

        XCTAssertNil(configuration.port)
        XCTAssertEqual(configuration.terminalStartupCommand, "ssh -tt dev@example.com")
    }

    private static func persistentSSHWorkspaceSnapshot(
        panel: SessionPanelSnapshot,
        focusedPanelId: UUID
    ) -> SessionWorkspaceSnapshot {
        SessionWorkspaceSnapshot(
            processTitle: "Persistent SSH",
            customTitle: "Persistent SSH",
            customDescription: nil,
            customColor: nil,
            isPinned: false,
            terminalScrollBarHidden: nil,
            currentDirectory: NSHomeDirectory(),
            focusedPanelId: focusedPanelId,
            layout: .pane(SessionPaneLayoutSnapshot(
                panelIds: [focusedPanelId],
                selectedPanelId: focusedPanelId
            )),
            panels: [panel],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil,
            remote: SessionRemoteWorkspaceSnapshot(
                transport: .ssh,
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                preserveAfterTerminalExit: true,
                skipDaemonBootstrap: nil
            )
        )
    }

    private static func browserPanelSnapshot(id: UUID) -> SessionPanelSnapshot {
        SessionPanelSnapshot(
            id: id,
            type: .browser,
            title: "Browser",
            customTitle: nil,
            directory: nil,
            isPinned: false,
            isManuallyUnread: false,
            listeningPorts: [],
            ttyName: nil,
            terminal: nil,
            browser: SessionBrowserPanelSnapshot(
                urlString: "http://localhost:3000",
                profileID: nil,
                shouldRenderWebView: true,
                pageZoom: 1,
                developerToolsVisible: false,
                backHistoryURLStrings: nil,
                forwardHistoryURLStrings: nil
            ),
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil
        )
    }

    private static func terminalPanelSnapshot(id: UUID) -> SessionPanelSnapshot {
        SessionPanelSnapshot(
            id: id,
            type: .terminal,
            title: "Terminal",
            customTitle: nil,
            directory: nil,
            isPinned: false,
            isManuallyUnread: false,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil
        )
    }
}
