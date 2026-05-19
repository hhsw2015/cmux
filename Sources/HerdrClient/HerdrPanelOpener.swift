import AppKit
import Bonsplit
import CMUXSessionDaemon
import Foundation
import GhosttyKit

/// Opens a real cmux panel (in the focused workspace) backed by a
/// herdr-managed PTY. The panel uses cmux's ordinary
/// TerminalSurface/TerminalPanel/bonsplit path — only the IO is
/// redirected to the herdr daemon via Ghostty's manual-IO mode. As a
/// result the panel inherits font, theme, background-opacity, blur,
/// keyboard, IME, focus, and tab-routing from cmux without any
/// additional plumbing.
@MainActor
enum HerdrPanelOpener {
    /// Open a herdr-backed panel at the focused pane in the focused
    /// workspace. Spawns / reuses the localhost herdr daemon, picks
    /// the first available pane, and binds a TerminalPanel to it.
    static func openLocalhostPanel() {
        // SwiftUI.NSApplicationDelegateAdaptor wraps our AppDelegate
        // inside an opaque proxy, so `NSApp.delegate as? AppDelegate`
        // fails. AppDelegate exposes a static `shared` for cases like
        // this where we need to reach it from outside the SwiftUI
        // environment.
        guard let appDelegate = AppDelegate.shared else {
            herdrPanelOpenerTrace("no AppDelegate.shared")
            return
        }
        // Resolve the focused tabManager via the front window — relying
        // on AppDelegate.tabManager (a global weak ref) was unreliable
        // when the menu was clicked from a Debug-menu interaction
        // because that ref isn't always pointing at the front window's
        // manager.
        let tabManager: TabManager? = {
            if let raw = NSApp.keyWindow?.identifier?.rawValue,
               raw.hasPrefix("cmux.main."),
               let id = UUID(uuidString: String(raw.dropFirst("cmux.main.".count))),
               let manager = appDelegate.tabManagerFor(windowId: id) {
                return manager
            }
            return appDelegate.tabManager
        }()
        guard let tabManager,
              let workspace = tabManager.tabs.first(where: { $0.id == tabManager.selectedTabId })
                ?? tabManager.tabs.first
        else {
            herdrPanelOpenerTrace("no focused workspace (tabManager=\(appDelegate.tabManager != nil) tabs=\(appDelegate.tabManager?.tabs.count ?? -1))")
            return
        }
        guard let focusedPane = workspace.bonsplitController.focusedPaneId else {
            herdrPanelOpenerTrace("no focused pane in workspace \(workspace.id)")
            return
        }

        let host = HerdrHost.localhost()
        let exec = (("~/.local/bin/herdr-cmux") as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: exec) else {
            herdrPanelOpenerTrace("missing binary at \(exec)")
            return
        }

        Task { @MainActor in
            do {
                try await openLocalhostPanelImpl(host: host, exec: exec, paneId: focusedPane, workspace: workspace)
            } catch {
                herdrPanelOpenerTrace("openLocalhostPanel failed: \(error)")
            }
        }
    }

    private static func openLocalhostPanelImpl(
        host: HerdrHost,
        exec: String,
        paneId: PaneID,
        workspace: Workspace
    ) async throws {
        // 1. List or create a workspace on the herdr daemon, then grab
        //    a pane / terminal id. Same logic as the debug window.
        let backend = try HerdrBackend(host: host, executablePath: exec)
        try await backend.start()
        let sessions = try await backend.listSessions()
        await backend.close()

        let workspaceId: String
        let socketPath = host.localApiSocketPath
        if let first = sessions.first {
            workspaceId = first.name
        } else {
            let api = HerdrApiClient(transport: HerdrTransportFactory.make(host: host))
            try await api.start()
            defer { Task { await api.close() } }
            let r = try await api.request(
                method: "workspace.create",
                params: ["focus": false, "label": "cmux-panel"]
            )
            guard let ws = r["workspace"] as? [String: Any],
                  let id = ws["workspace_id"] as? String
            else {
                herdrPanelOpenerTrace("workspace.create returned no id")
                return
            }
            workspaceId = id
        }

        let api = HerdrApiClient(transport: HerdrTransportFactory.make(host: host))
        try await api.start()
        defer { Task { await api.close() } }
        let panesResp = try await api.request(
            method: "pane.list",
            params: ["workspace_id": workspaceId]
        )
        guard let panes = panesResp["panes"] as? [[String: Any]],
              let first = panes.first,
              let terminalId = first["terminal_id"] as? String,
              let herdrPaneId = first["pane_id"] as? String
        else {
            herdrPanelOpenerTrace("no pane in workspace \(workspaceId)")
            return
        }

        _ = try await wireHerdrBackedPanel(
            workspace: workspace,
            cmuxPaneId: paneId,
            host: host,
            terminalId: terminalId,
            herdrPaneId: herdrPaneId,
            executablePath: exec,
            socketPath: socketPath,
            focus: true
        )
    }

    /// Per-pane wiring shared by the single-panel opener and the
    /// workspace materializer. Builds the display client + surface
    /// controller + io callback, calls
    /// `workspace.newTerminalSurface(externalIo:)`, waits for Ghostty
    /// to construct the C surface, binds the controller, and starts
    /// the output pump + resize observer.
    @discardableResult
    static func wireHerdrBackedPanel(
        workspace: Workspace,
        cmuxPaneId: PaneID,
        host: HerdrHost,
        terminalId: String,
        herdrPaneId: String,
        executablePath: String,
        socketPath: String,
        focus: Bool
    ) async throws -> TerminalPanel? {
        let displayClient = HerdrDisplayClient(
            host: host,
            terminalId: terminalId,
            executablePath: executablePath,
            cols: 80,
            rows: 24
        )
        // Use takeover so we win against any leftover subprocess from
        // a prior cmux DEV launch — subprocesses spawned by Process
        // aren't always reaped when the parent exits, so the herdr
        // daemon may still hold a stale attach owner for our
        // terminal_id.
        try await displayClient.start(takeover: true)
        let controller = HerdrSurfaceController(displayClient: displayClient)
        let panelId = UUID()
        let box = HerdrIoCallbackBox(panelId: panelId, controller: controller)
        let ctxRaw = Unmanaged.passRetained(box).toOpaque()
        let binding = TerminalSurface.ExternalIoBinding(
            writeCb: herdrPanelIoWriteCallback,
            userdata: ctxRaw
        )

        guard let panel = workspace.newTerminalSurface(
            inPane: cmuxPaneId,
            focus: focus,
            externalIo: binding
        ) else {
            herdrPanelOpenerTrace("workspace.newTerminalSurface returned nil for pane \(herdrPaneId)")
            displayClient.stop()
            Unmanaged<HerdrIoCallbackBox>.fromOpaque(ctxRaw).release()
            return nil
        }

        // Wait for the Ghostty surface to be created. cmux defers
        // surface construction to viewDidMoveToWindow on the
        // GhosttyNSView, which lands on the next runloop tick.
        var ghosttySurfaceRef: ghostty_surface_t?
        for _ in 0..<25 {
            if let s = panel.surface.surface {
                ghosttySurfaceRef = s
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let ghosttySurface = ghosttySurfaceRef else {
            herdrPanelOpenerTrace("ghostty surface still nil after 500ms for pane \(herdrPaneId)")
            displayClient.stop()
            Unmanaged<HerdrIoCallbackBox>.fromOpaque(ctxRaw).release()
            return nil
        }
        controller.bindSurfaceWithoutPump(ghosttySurface)

        HerdrPanelRegistry.shared.register(
            panelId: panel.id,
            entry: HerdrPanelRegistry.Entry(
                displayClient: displayClient,
                controller: controller,
                ioCallbackContext: ctxRaw,
                host: host,
                paneId: herdrPaneId,
                terminalId: terminalId,
                pumpTask: nil
            )
        )

        let pump = Task { [displayClient, weak panel] in
            for await chunk in displayClient.output {
                guard let surface = panel?.surface.surface else { break }
                chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    guard let base = raw.baseAddress else { return }
                    let cChars = base.assumingMemoryBound(to: CChar.self)
                    ghostty_surface_process_output(surface, cChars, UInt(raw.count))
                }
            }
        }
        HerdrPanelRegistry.shared.attachPump(panelId: panel.id, task: pump)

        installPanelResizeObserver(
            panelId: panel.id,
            hostedView: panel.surface.hostedView,
            surface: ghosttySurface,
            paneId: herdrPaneId,
            socketPath: socketPath
        )

        herdrPanelOpenerTrace("herdr panel wired panelId=\(panel.id) terminalId=\(terminalId)")
        return panel
    }

    /// Multi-pane variant of `openLocalhostPanel`: pulls the herdr
    /// daemon's authoritative BSP layout for a workspace tab, builds
    /// a `HerdrLayoutApplyPlan`, and materializes it onto cmux's
    /// bonsplit by recursively splitting the focused pane and wiring
    /// each leaf to a herdr-backed terminal. The focused pane becomes
    /// slot 0 — its existing tabs are left in place, with herdr-backed
    /// tabs added alongside them.
    static func openLocalhostWorkspace() {
        openWorkspace(host: HerdrHost.localhost())
    }

    /// Open the focused cmux pane as a herdr workspace mirror. Works
    /// for any `HerdrHost` — local UDS or SSH stdio — because the
    /// transport factory + opener impl are transport-agnostic.
    static func openWorkspace(host: HerdrHost) {
        openWorkspace(host: host, requestedWorkspaceId: nil)
    }

    /// Sidebar-driven entry point: open a specific workspace by id.
    /// Skips the auto-select / persisted-fallback / create-if-empty
    /// logic so the user gets exactly the workspace they clicked.
    static func openWorkspace(host: HerdrHost, workspaceId: String) {
        openWorkspace(host: host, requestedWorkspaceId: workspaceId)
    }

    private static func openWorkspace(host: HerdrHost, requestedWorkspaceId: String?) {
        guard let appDelegate = AppDelegate.shared else {
            herdrPanelOpenerTrace("workspace: no AppDelegate.shared")
            return
        }
        // Already attached? Focus the existing cmux workspace instead
        // of double-attaching the same herdr workspace.
        if let workspaceId = requestedWorkspaceId,
           let existing = HerdrTabRegistry.shared.allBindings.first(where: {
               $0.host.id == host.id && $0.workspaceId == workspaceId
           }),
           let existingWorkspace = existing.workspace {
            let managers = appDelegate.mainWindowContexts.values.compactMap { $0.tabManager }
            for manager in managers
            where manager.tabs.contains(where: { $0.id == existingWorkspace.id }) {
                manager.selectedTabId = existingWorkspace.id
                herdrPanelOpenerTrace(
                    "workspace: focused existing binding for \(host.displayName)/\(workspaceId)"
                )
                return
            }
        }
        let tabManager: TabManager? = {
            if let raw = NSApp.keyWindow?.identifier?.rawValue,
               raw.hasPrefix("cmux.main."),
               let id = UUID(uuidString: String(raw.dropFirst("cmux.main.".count))),
               let manager = appDelegate.tabManagerFor(windowId: id) {
                return manager
            }
            return appDelegate.tabManager
        }()
        guard let tabManager,
              let workspace = tabManager.tabs.first(where: { $0.id == tabManager.selectedTabId })
                ?? tabManager.tabs.first
        else {
            herdrPanelOpenerTrace("workspace: no focused workspace")
            return
        }
        guard let focusedPane = workspace.bonsplitController.focusedPaneId else {
            herdrPanelOpenerTrace("workspace: no focused pane in workspace \(workspace.id)")
            return
        }
        let exec = (("~/.local/bin/herdr-cmux") as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: exec) else {
            herdrPanelOpenerTrace("workspace: missing binary at \(exec)")
            return
        }
        Task { @MainActor in
            do {
                try await openLocalhostWorkspaceImpl(
                    host: host,
                    exec: exec,
                    rootPaneId: focusedPane,
                    workspace: workspace,
                    requestedWorkspaceId: requestedWorkspaceId
                )
            } catch {
                herdrPanelOpenerTrace("openWorkspace failed for host \(host.displayName): \(error)")
            }
        }
    }

    private static func openLocalhostWorkspaceImpl(
        host: HerdrHost,
        exec: String,
        rootPaneId: PaneID,
        workspace: Workspace,
        requestedWorkspaceId: String? = nil
    ) async throws {
        let socketPath = host.localApiSocketPath

        let backend = try HerdrBackend(host: host, executablePath: exec)
        try await backend.start()
        let sessions = try await backend.listSessions()
        let probe = await backend.probeCapabilities()
        await backend.close()

        switch probe {
        case .ok(let version):
            herdrPanelOpenerTrace("workspace: capabilities ok (daemon version \(version))")
        case .incompatible(let reason):
            herdrPanelOpenerTrace("workspace: incompatible daemon — \(reason)")
            return
        }

        let api = HerdrApiClient(transport: HerdrTransportFactory.make(host: host))
        try await api.start()
        defer { Task { await api.close() } }

        // E4: prefer the previously-attached workspace+tab if it still
        // exists on the daemon. This makes Cmd+Q + relaunch + click
        // "Open Herdr Workspace" land back on the same panes.
        let workspaceId: String
        let activeTabId: String
        if let requested = requestedWorkspaceId {
            // Sidebar / explicit-id path: skip auto-select. We still
            // need active_tab_id, fetched via workspace.get.
            let wsResp = try await api.request(
                method: "workspace.get",
                params: ["workspace_id": requested]
            )
            guard let wsInfo = wsResp["workspace"] as? [String: Any],
                  let requestedActiveTabId = wsInfo["active_tab_id"] as? String
            else {
                herdrPanelOpenerTrace("workspace: workspace.get(\(requested)) returned no active_tab_id")
                return
            }
            workspaceId = requested
            activeTabId = requestedActiveTabId
            herdrPanelOpenerTrace("workspace: opening explicit \(workspaceId) tab=\(activeTabId)")
        } else if let persisted = HerdrPersistence.shared.entry(forHostSession: host.sessionName),
           let resolved = await Self.resolvePersistedWorkspace(
               api: api,
               sessions: sessions,
               persisted: persisted
           ) {
            workspaceId = resolved.workspaceId
            activeTabId = resolved.tabId
            herdrPanelOpenerTrace("workspace: reusing persisted \(workspaceId) tab=\(activeTabId)")
        } else if let first = sessions.first {
            // Fall back: first existing workspace, its active tab.
            let wsResp = try await api.request(
                method: "workspace.get",
                params: ["workspace_id": first.name]
            )
            guard let wsInfo = wsResp["workspace"] as? [String: Any],
                  let firstActiveTabId = wsInfo["active_tab_id"] as? String
            else {
                herdrPanelOpenerTrace("workspace: workspace.get returned no active_tab_id")
                return
            }
            workspaceId = first.name
            activeTabId = firstActiveTabId
        } else {
            // No existing workspace — create one.
            let r = try await api.request(
                method: "workspace.create",
                params: ["focus": false, "label": "cmux-workspace"]
            )
            guard let ws = r["workspace"] as? [String: Any],
                  let id = ws["workspace_id"] as? String,
                  let firstActiveTabId = ws["active_tab_id"] as? String
            else {
                herdrPanelOpenerTrace("workspace: workspace.create returned no id/tab")
                return
            }
            workspaceId = id
            activeTabId = firstActiveTabId
        }

        // Map herdr pane id -> terminal id from pane.list, so the
        // executor's paneFactory can spin up display clients pointed
        // at the right terminal.
        let panesResp = try await api.request(
            method: "pane.list",
            params: ["workspace_id": workspaceId]
        )
        guard let panes = panesResp["panes"] as? [[String: Any]] else {
            herdrPanelOpenerTrace("workspace: pane.list returned no panes")
            return
        }
        var terminalIdByPane: [String: String] = [:]
        for pane in panes {
            if let pid = pane["pane_id"] as? String,
               let tid = pane["terminal_id"] as? String {
                terminalIdByPane[pid] = tid
            }
        }

        let tree = try await api.layoutSnapshot(
            workspaceId: workspaceId,
            tabId: activeTabId
        )
        let spec = HerdrLayoutSpec(from: tree)
        let plan = HerdrLayoutApplyPlan(spec: spec)
        herdrPanelOpenerTrace(
            "workspace: workspaceId=\(workspaceId) tabId=\(activeTabId) panes=\(spec.root.paneCount) plan_steps=\(plan.steps.count)"
        )

        // Materialize the bonsplit tree first (synchronous splits).
        // paneFactory is a no-op here — populating each pane with a
        // herdr-backed terminal is async, so we collect the leaves
        // and wire them in a second pass.
        var leaves: [(cmuxPaneId: UUID, herdrPaneId: String)] = []
        let result = HerdrLayoutExecutor.execute(
            plan: plan,
            rootCmuxPaneId: rootPaneId.id,
            controller: workspace.bonsplitController
        ) { cmuxPaneId, herdrPaneId in
            leaves.append((cmuxPaneId: cmuxPaneId, herdrPaneId: herdrPaneId))
        }

        for (idx, leaf) in leaves.enumerated() {
            guard let terminalId = terminalIdByPane[leaf.herdrPaneId] else {
                herdrPanelOpenerTrace("workspace: no terminal_id for pane \(leaf.herdrPaneId)")
                continue
            }
            let shouldFocus = (result.focusedCmuxPaneId == leaf.cmuxPaneId) || (result.focusedCmuxPaneId == nil && idx == 0)
            do {
                _ = try await wireHerdrBackedPanel(
                    workspace: workspace,
                    cmuxPaneId: PaneID(id: leaf.cmuxPaneId),
                    host: host,
                    terminalId: terminalId,
                    herdrPaneId: leaf.herdrPaneId,
                    executablePath: exec,
                    socketPath: socketPath,
                    focus: shouldFocus
                )
            } catch {
                herdrPanelOpenerTrace("workspace: wire failed for pane \(leaf.herdrPaneId): \(error)")
            }
        }

        if let focusedCmux = result.focusedCmuxPaneId {
            workspace.bonsplitController.focusPane(PaneID(id: focusedCmux))
        }

        let binding = HerdrTabBinding(
            host: host,
            workspaceId: workspaceId,
            tabId: activeTabId,
            rootCmuxPaneId: rootPaneId.id,
            paneBindings: result.registry,
            workspace: workspace
        )
        HerdrTabRegistry.shared.register(key: rootPaneId.id, binding: binding)
        HerdrDividerSync.prime(
            binding: binding,
            treeSnapshot: workspace.bonsplitController.treeSnapshot()
        )
        await HerdrEventPump.shared.acquire(host: host)
        HerdrPersistence.shared.record(host: host, workspaceId: workspaceId, tabId: activeTabId)
    }

    /// Verify the persisted workspace+tab still exists on the daemon
    /// before reusing it. If listSessions doesn't have the workspace,
    /// or workspace.get returns a different active tab, we fall back
    /// to the first available.
    private static func resolvePersistedWorkspace(
        api: HerdrApiClient,
        sessions: [DaemonSession],
        persisted: HerdrPersistence.Entry
    ) async -> (workspaceId: String, tabId: String)? {
        guard sessions.contains(where: { $0.name == persisted.workspaceId }) else {
            return nil
        }
        guard let resp = try? await api.request(
            method: "workspace.get",
            params: ["workspace_id": persisted.workspaceId]
        ) else {
            return nil
        }
        guard let wsInfo = resp["workspace"] as? [String: Any] else {
            return nil
        }
        // If the tab still exists in the workspace, reuse it; else use
        // the workspace's current active tab.
        guard let tabsResp = try? await api.request(
            method: "tab.list",
            params: ["workspace_id": persisted.workspaceId]
        ) else {
            return nil
        }
        guard let tabs = tabsResp["tabs"] as? [[String: Any]] else {
            return nil
        }
        let tabExists = tabs.contains { ($0["tab_id"] as? String) == persisted.tabId }
        if tabExists {
            return (persisted.workspaceId, persisted.tabId)
        }
        guard let activeTabId = wsInfo["active_tab_id"] as? String else {
            return nil
        }
        return (persisted.workspaceId, activeTabId)
    }

    private static func installPanelResizeObserver(
        panelId: UUID,
        hostedView: NSView,
        surface: ghostty_surface_t,
        paneId: String,
        socketPath: String
    ) {
        hostedView.postsFrameChangedNotifications = true
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: hostedView,
            queue: .main
        ) { _ in
            herdrPanelOpenerTrace("panel hostedView frameDidChange")
            schedulePanelResize(
                panelId: panelId,
                surface: surface,
                paneId: paneId,
                socketPath: socketPath
            )
        }
        HerdrPanelRegistry.shared.setResizeObserver(panelId: panelId, observer: observer)
        herdrPanelOpenerTrace("resize observer installed for panel \(panelId)")
        // Fire once so the daemon picks up the actual visible grid
        // immediately rather than 80x24 (the spawn default).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            schedulePanelResize(
                panelId: panelId,
                surface: surface,
                paneId: paneId,
                socketPath: socketPath
            )
        }
    }

    private static func schedulePanelResize(
        panelId: UUID,
        surface: ghostty_surface_t,
        paneId: String,
        socketPath: String
    ) {
        let debounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            forwardPanelSize(
                panelId: panelId,
                surface: surface,
                paneId: paneId,
                socketPath: socketPath
            )
        }
        HerdrPanelRegistry.shared.setResizeDebounceTask(panelId: panelId, task: debounce)
    }

    private static func forwardPanelSize(
        panelId: UUID,
        surface: ghostty_surface_t,
        paneId: String,
        socketPath: String
    ) {
        let size = ghostty_surface_size(surface)
        herdrPanelOpenerTrace("forwardPanelSize panelId=\(panelId) cols=\(size.columns) rows=\(size.rows)")
        guard size.columns > 0, size.rows > 0 else { return }
        if let entry = HerdrPanelRegistry.shared.entry(panelId: panelId),
           entry.lastReportedCols == size.columns,
           entry.lastReportedRows == size.rows {
            herdrPanelOpenerTrace("forwardPanelSize unchanged \(size.columns)x\(size.rows), skip")
            return
        }
        HerdrPanelRegistry.shared.setLastReportedSize(
            panelId: panelId,
            cols: size.columns,
            rows: size.rows
        )
        Task.detached(priority: .userInitiated) {
            await HerdrPaneResizeRPC.sendOneShotPaneResize(
                socketPath: socketPath,
                paneId: paneId,
                cols: size.columns,
                rows: size.rows,
                cellWidthPx: size.cell_width_px,
                cellHeightPx: size.cell_height_px
            )
        }
    }
}

/// One-shot UDS sender for `pane.resize`. herdr's API socket reads
/// one line then closes, so each resize tick opens a fresh AF_UNIX
/// socket. Predates HerdrOneShotRPC + the transport factory; could
/// be migrated to those for SSH support, but the resize path only
/// runs for localhost panels (the resize observer feeds it ghostty
/// surface events) so the direct socket call is fine for now.
@MainActor
private enum HerdrPaneResizeRPC {
    static func sendOneShotPaneResize(
        socketPath: String,
        paneId: String,
        cols: UInt16,
        rows: UInt16,
        cellWidthPx: UInt32,
        cellHeightPx: UInt32
    ) async {
        let envelope: [String: Any] = [
            "id": "cmux_panelresize_\(Int(Date().timeIntervalSince1970 * 1000))",
            "method": "pane.resize",
            "params": [
                "pane_id": paneId,
                "cols": Int(cols),
                "rows": Int(rows),
                "cell_width_px": Int(cellWidthPx),
                "cell_height_px": Int(cellHeightPx),
            ],
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: envelope) else {
            await MainActor.run { herdrPanelOpenerTrace("send: JSON encode failed") }
            return
        }
        line.append(0x0A)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            await MainActor.run { herdrPanelOpenerTrace("send: socket() failed errno=\(errno)") }
            return
        }
        defer { _ = Darwin.close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < maxLen else {
            await MainActor.run { herdrPanelOpenerTrace("send: path too long") }
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            pathPtr.withMemoryRebound(to: CChar.self, capacity: maxLen) { rebound in
                for i in 0..<pathBytes.count {
                    rebound[i] = CChar(bitPattern: pathBytes[i])
                }
                rebound[pathBytes.count] = 0
            }
        }
        let connectResult = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let err = errno
            await MainActor.run { herdrPanelOpenerTrace("send: connect failed path=\(socketPath) errno=\(err)") }
            return
        }
        var ok = true
        line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { ok = false; return }
            var written = 0
            while written < raw.count {
                let n = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if n <= 0 { ok = false; return }
                written += n
            }
        }
        await MainActor.run {
            herdrPanelOpenerTrace("send: pane.resize \(cols)x\(rows) ok=\(ok)")
        }
    }
}

private func herdrPanelOpenerTrace(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] [HerdrPanelOpener] \(message)\n"
    if let data = line.data(using: .utf8) {
        if let handle = FileHandle(forWritingAtPath: "/tmp/herdr-debug.log") {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: "/tmp/herdr-debug.log", contents: data)
        }
    }
}
