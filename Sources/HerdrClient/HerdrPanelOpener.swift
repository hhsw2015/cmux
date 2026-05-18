#if DEBUG
import AppKit
import Bonsplit
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
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let tabManager = appDelegate.tabManager,
              let workspace = tabManager.tabs.first(where: { $0.id == tabManager.selectedTabId })
        else {
            herdrPanelOpenerTrace("no focused workspace")
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
        let socketPath = (("~/.config/herdr/sessions/" + host.sessionName + "/herdr.sock") as NSString)
            .expandingTildeInPath
        if let first = sessions.first {
            workspaceId = first.name
        } else {
            let api = HerdrApiClient(transport: LocalUDSTransport(socketPath: socketPath))
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

        let api = HerdrApiClient(transport: LocalUDSTransport(socketPath: socketPath))
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

        // 2. Build display client + surface controller + io callback
        //    box BEFORE creating the cmux panel so the binding exists
        //    at the moment Ghostty constructs the C surface.
        let displayClient = HerdrDisplayClient(
            host: host,
            terminalId: terminalId,
            executablePath: exec,
            cols: 80,
            rows: 24
        )
        try await displayClient.start()
        let controller = HerdrSurfaceController(displayClient: displayClient)
        let panelId = UUID()
        let box = HerdrIoCallbackBox(panelId: panelId, controller: controller)
        let ctxRaw = Unmanaged.passRetained(box).toOpaque()
        let binding = TerminalSurface.ExternalIoBinding(
            writeCb: herdrPanelIoWriteCallback,
            userdata: ctxRaw
        )

        // 3. Ask the workspace to create a normal terminal panel that
        //    routes IO through our binding. The panel will go through
        //    cmux's full TerminalPanel/bonsplit lifecycle, so it picks
        //    up the same theme/font/transparency/blur as every other
        //    panel in the workspace.
        guard let panel = workspace.newTerminalSurface(
            inPane: paneId,
            focus: true,
            externalIo: binding
        ) else {
            herdrPanelOpenerTrace("workspace.newTerminalSurface returned nil")
            displayClient.stop()
            Unmanaged<HerdrIoCallbackBox>.fromOpaque(ctxRaw).release()
            return
        }
        controller.bindSurfaceWithoutPump(panel.surface.surface!)

        // 4. Register so the controller + display client + box outlive
        //    this scope. Cleanup hook runs in workspace teardown.
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

        // 5. Single AsyncStream consumer: pump display client output
        //    into ghostty_surface_process_output on the panel's
        //    surface. Bound to the panel id so registry cleanup
        //    cancels it.
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
        herdrPanelOpenerTrace("herdr panel opened panelId=\(panel.id) terminalId=\(terminalId)")
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
#endif
