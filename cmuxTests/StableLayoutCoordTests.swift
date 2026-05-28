import Foundation
import Testing
@testable import cmux

@Suite("StableLayoutCoord")
struct StableLayoutCoordTests {
    @Test func roundTripRawValue() {
        let coord = StableLayoutCoord(
            workspaceTitle: "cmux",
            topTabTitle: "backend",
            splitPath: "L/R/L",
            paneIndex: 0,
            panelIndexInPane: 1
        )
        let parsed = StableLayoutCoord(rawValue: coord.rawValue)
        #expect(parsed == coord)
    }

    @Test func emptyTopTabRoundTrip() throws {
        let coord = StableLayoutCoord(
            workspaceTitle: "ws",
            topTabTitle: nil,
            splitPath: "",
            paneIndex: 0,
            panelIndexInPane: 0
        )
        let parsed = try #require(StableLayoutCoord(rawValue: coord.rawValue))
        #expect(parsed.topTabTitle == nil)
        #expect(parsed.splitPath == "")
    }

    @Test func malformedRawValueRejected() {
        #expect(StableLayoutCoord(rawValue: "only:colons:not:units") == nil)
        #expect(StableLayoutCoord(rawValue: "") == nil)
    }
}

@Suite("StableLayoutCoordStamper")
struct StableLayoutCoordStamperTests {
    @Test func stampsLeafPaneAtRoot() {
        let panelId = UUID()
        let snap = makeSnapshot(workspaceTitle: "cmux", layout: pane(panelIds: [panelId]), panels: [panel(id: panelId)])

        let stamped = StableLayoutCoordStamper.stamp(snap)

        let coord = stamped.windows[0].tabManager.workspaces[0].panels[0].stableCoord
        #expect(coord?.workspaceTitle == "cmux")
        #expect(coord?.topTabTitle == nil)
        #expect(coord?.splitPath == "")
        #expect(coord?.panelIndexInPane == 0)
    }

    @Test func stampsSplitPath() {
        let leftId = UUID()
        let rightTopId = UUID()
        let rightBotId = UUID()
        let layout: SessionWorkspaceLayoutSnapshot = .split(SessionSplitLayoutSnapshot(
            orientation: .horizontal,
            dividerPosition: 0.5,
            first: pane(panelIds: [leftId]),
            second: .split(SessionSplitLayoutSnapshot(
                orientation: .vertical,
                dividerPosition: 0.5,
                first: pane(panelIds: [rightTopId]),
                second: pane(panelIds: [rightBotId])
            ))
        ))
        let snap = makeSnapshot(
            workspaceTitle: "ws",
            layout: layout,
            panels: [panel(id: leftId), panel(id: rightTopId), panel(id: rightBotId)]
        )

        let stamped = StableLayoutCoordStamper.stamp(snap)
        let panels = stamped.windows[0].tabManager.workspaces[0].panels
        let coordsByPanel = Dictionary(uniqueKeysWithValues: panels.map { ($0.id, $0.stableCoord) })

        #expect(coordsByPanel[leftId]??.splitPath == "L")
        #expect(coordsByPanel[rightTopId]??.splitPath == "R/L")
        #expect(coordsByPanel[rightBotId]??.splitPath == "R/R")
    }

    @Test func stampsTopTabsSeparately() {
        let aId = UUID()
        let bId = UUID()
        var ws = workspaceShell(title: "main")
        ws.panels = [panel(id: aId), panel(id: bId)]
        ws.layoutTabs = [
            SessionWorkspaceLayoutTabSnapshot(id: UUID(), title: "alpha", layout: pane(panelIds: [aId])),
            SessionWorkspaceLayoutTabSnapshot(id: UUID(), title: "beta", layout: pane(panelIds: [bId]))
        ]
        let snap = wrapSingleWorkspace(ws)

        let stamped = StableLayoutCoordStamper.stamp(snap)
        let panels = stamped.windows[0].tabManager.workspaces[0].panels
        let map = Dictionary(uniqueKeysWithValues: panels.map { ($0.id, $0.stableCoord) })
        #expect(map[aId]??.topTabTitle == "alpha")
        #expect(map[bId]??.topTabTitle == "beta")
    }

    @Test func usesCustomTitleOverProcessTitle() {
        let id = UUID()
        var ws = workspaceShell(title: "process-title")
        ws.customTitle = "preferred"
        ws.panels = [panel(id: id)]
        ws.layout = pane(panelIds: [id])
        let snap = wrapSingleWorkspace(ws)

        let stamped = StableLayoutCoordStamper.stamp(snap)
        #expect(stamped.windows[0].tabManager.workspaces[0].panels[0].stableCoord?.workspaceTitle == "preferred")
    }
}

@Suite("StableLayoutCoordResolver")
struct StableLayoutCoordResolverTests {
    @Test func resolverFindsPanelAfterUUIDDrift() throws {
        let originalId = UUID()
        let snap = makeSnapshot(
            workspaceTitle: "cmux",
            layout: pane(panelIds: [originalId]),
            panels: [panel(id: originalId)]
        )
        let stamped = StableLayoutCoordStamper.stamp(snap)
        let coord = try #require(stamped.windows[0].tabManager.workspaces[0].panels[0].stableCoord)

        // Simulate UUID drift: encode + decode preserves coords; on a fresh
        // process the resolver should still hand back the panel id stored in the
        // snapshot, even though that id would not match a freshly minted UUID.
        let resolver = StableLayoutCoordResolver(snapshot: stamped)
        #expect(resolver.panelId(at: coord) == originalId)
    }

    @Test func resolverIsEmptyForUnstampedSnapshot() {
        let snap = makeSnapshot(
            workspaceTitle: "cmux",
            layout: pane(panelIds: [UUID()]),
            panels: [panel(id: UUID())]
        )
        // Skip stamping — snapshots persisted before Phase 1.1
        let resolver = StableLayoutCoordResolver(snapshot: snap)
        #expect(resolver.coordCount == 0)
    }
}

// MARK: - Test helpers

private func panel(id: UUID) -> SessionPanelSnapshot {
    SessionPanelSnapshot(
        id: id,
        type: .terminal,
        title: nil,
        customTitle: nil,
        directory: nil,
        isPinned: false,
        isManuallyUnread: false,
        hasUnreadIndicator: nil,
        restoredUnreadContributesToWorkspace: nil,
        notifications: nil,
        gitBranch: nil,
        listeningPorts: [],
        ttyName: nil,
        terminal: nil,
        browser: nil,
        markdown: nil,
        filePreview: nil,
        rightSidebarTool: nil
    )
}

private func pane(panelIds: [UUID]) -> SessionWorkspaceLayoutSnapshot {
    .pane(SessionPaneLayoutSnapshot(panelIds: panelIds, selectedPanelId: panelIds.first))
}

private func workspaceShell(title: String) -> SessionWorkspaceSnapshot {
    SessionWorkspaceSnapshot(
        processTitle: title,
        customTitle: nil,
        customDescription: nil,
        customColor: nil,
        isPinned: false,
        isManuallyUnread: nil,
        hasUnreadIndicator: nil,
        notifications: nil,
        terminalScrollBarHidden: nil,
        currentDirectory: "/",
        focusedPanelId: nil,
        layout: pane(panelIds: []),
        layoutTabs: nil,
        selectedLayoutTabId: nil,
        panels: [],
        statusEntries: [],
        logEntries: [],
        progress: nil,
        gitBranch: nil,
        remote: nil
    )
}

private func wrapSingleWorkspace(_ ws: SessionWorkspaceSnapshot) -> AppSessionSnapshot {
    AppSessionSnapshot(
        version: 1,
        createdAt: 0,
        windows: [
            SessionWindowSnapshot(
                frame: nil,
                display: nil,
                tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: [ws]),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
            )
        ]
    )
}

private func makeSnapshot(
    workspaceTitle: String,
    layout: SessionWorkspaceLayoutSnapshot,
    panels: [SessionPanelSnapshot]
) -> AppSessionSnapshot {
    var ws = workspaceShell(title: workspaceTitle)
    ws.layout = layout
    ws.panels = panels
    return wrapSingleWorkspace(ws)
}
