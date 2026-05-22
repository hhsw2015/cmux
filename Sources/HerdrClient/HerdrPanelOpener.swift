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
enum HerdrPanelOpenerError: Error {
    /// AutoReattach / openWorkspace was invoked but the daemon has no
    /// workspace to attach to and nothing usable is persisted (e.g.
    /// the user just ran `herdr session delete`). Caller should drop
    /// the placeholder cmux tab and abort silently.
    case noWorkspaceAvailable
}

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
        guard let exec = HerdrLocalBinary.resolve() else {
            herdrPanelOpenerTrace("missing herdr-cmux binary")
            presentMissingLocalBinaryAlert(path: HerdrLocalBinary.userInstallPath)
            return
        }

        Task { @MainActor in
            HostHealthStore.shared.reportChecking(hostId: host.id)
            do {
                try await openLocalhostPanelImpl(host: host, exec: exec, paneId: focusedPane, workspace: workspace)
                HostHealthStore.shared.reportOnline(hostId: host.id)
            } catch {
                herdrPanelOpenerTrace("openLocalhostPanel failed: \(error)")
                let reason = friendlyErrorMessage(error, isRemote: false)
                HostHealthStore.shared.reportOffline(hostId: host.id, reason: reason)
                presentOpenFailureAlert(host: host, error: error)
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
            let r = try await HerdrOneShotRPC.request(
                host: host,
                method: "workspace.create",
                params: [
                    "focus": false,
                    "label": "cmux-panel",
                    "cwd": NSHomeDirectory(),
                ]
            )
            guard let ws = r["workspace"] as? [String: Any],
                  let id = ws["workspace_id"] as? String
            else {
                herdrPanelOpenerTrace("workspace.create returned no id")
                return
            }
            workspaceId = id
        }

        let panesResp = try await HerdrOneShotRPC.request(
            host: host,
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
            host: host
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
        openWorkspace(host: host, requestedWorkspaceId: nil, reuseCmuxWorkspaceId: nil)
    }

    /// Sidebar-driven entry point: open a specific workspace by id.
    /// Skips the auto-select / persisted-fallback / create-if-empty
    /// logic so the user gets exactly the workspace they clicked.
    static func openWorkspace(host: HerdrHost, workspaceId: String) {
        openWorkspace(host: host, requestedWorkspaceId: workspaceId, reuseCmuxWorkspaceId: nil)
    }

    /// Auto-reattach entry point: rebind an existing cmux Workspace
    /// (one cmux restored from its own state but no longer bound to
    /// herdr) to the daemon. Without this path every quit/reopen
    /// cycle leaves the user with a duplicate sidebar entry — the
    /// stale local stubs cmux restored, plus a fresh herdr-bound
    /// workspace this opener creates.
    static func openWorkspace(host: HerdrHost, reuseCmuxWorkspaceId: UUID) {
        openWorkspace(
            host: host,
            requestedWorkspaceId: nil,
            reuseCmuxWorkspaceId: reuseCmuxWorkspaceId
        )
    }

    /// Combined: reuse an existing cmux Workspace AND attach to a
    /// specific existing herdr workspace (skipping the
    /// create-if-missing logic). Used by HerdrAutoReattach when
    /// restoring multiple persisted bindings — each call resolves
    /// to one cmux+herdr pair.
    static func openWorkspace(
        host: HerdrHost,
        attachExistingHerdrWorkspaceId: String,
        reuseCmuxWorkspaceId: UUID
    ) {
        openWorkspace(
            host: host,
            requestedWorkspaceId: attachExistingHerdrWorkspaceId,
            reuseCmuxWorkspaceId: reuseCmuxWorkspaceId
        )
    }

    private static func openWorkspace(
        host: HerdrHost,
        requestedWorkspaceId: String?,
        reuseCmuxWorkspaceId: UUID?
    ) {
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
        guard let tabManager else {
            herdrPanelOpenerTrace("workspace: no tabManager")
            return
        }
        // Reuse path: auto-reattach found a previously-bound cmux
        // Workspace in this session's tabs. Adopt it instead of
        // creating a sibling — the stale local panels will be torn
        // down by preExistingPanelIds cleanup once the herdr panel
        // is wired in.
        let reusedWorkspace: Workspace? = {
            guard let target = reuseCmuxWorkspaceId else { return nil }
            return tabManager.tabs.first(where: { $0.id == target })
        }()
        let workspace: Workspace = {
            if let existing = reusedWorkspace {
                tabManager.selectedTabId = existing.id
                // Restored bonsplit tree has stale panes from the
                // previous session — each holds a TerminalPanel whose
                // Ghostty surface is unbound (no PTY, no content).
                // Collapse to a single root pane so HerdrLayoutExecutor
                // builds the daemon's tree from scratch on top of one
                // empty pane, instead of stacking the new tree under
                // the stale one. preExistingPanelIds cleanup at the
                // end of openLocalhostWorkspaceImpl handles the final
                // stub panel.
                //
                // Mark every embedded tab as force-closeable so the
                // shouldClosePane confirmation gate (which can fire
                // for restored shell-activity state even when the PTY
                // is gone) doesn't reject the teardown.
                existing.markAllTabsForceCloseable()
                let allIds = existing.bonsplitController.allPaneIds
                if allIds.count > 1 {
                    for paneId in allIds.dropFirst() {
                        existing.bonsplitController.closePane(paneId)
                    }
                }
                // After collapse, force focus to the surviving root
                // pane. The previously focused pane may have been one
                // of the closed siblings; downstream wireHerdrBackedPanel
                // splits the focused pane to attach the herdr panel,
                // so leaving focusedPaneId stale would no-op or split
                // a non-existent pane.
                if let survivor = existing.bonsplitController.allPaneIds.first {
                    existing.bonsplitController.focusPane(survivor)
                }
                return existing
            }
            // Always create a fresh cmux workspace tab for a persistent
            // workspace open. Reusing the focused tab silently rebound
            // the user's existing workspace into a herdr session and
            // (erroneously) propagated the daemon's default label back
            // into its customTitle, overwriting the user-given name.
            // Workspace.init unconditionally creates an initial local
            // TerminalPanel; wireHerdrBackedPanel then adds a
            // herdr-backed panel in the same pane, leaving two tabs
            // side-by-side. After we wire the herdr panel below, every
            // TerminalPanel that existed on entry must be closed so the
            // user sees a single herdr-backed tab matching daemon-side
            // leaf count. eagerLoad = false skips the background
            // Ghostty surface boot since we'd tear it down 200ms later
            // anyway.
            // Title left at default until openLocalhostWorkspaceImpl
            // resolves which daemon workspace this attaches to and
            // backfills workspace.title with the herdr-side label.
            return tabManager.addWorkspace(
                title: nil,
                select: true,
                eagerLoadTerminal: false
            )
        }()
        let preExistingPanelIds = Set(workspace.panels.keys)
        guard let focusedPane = workspace.bonsplitController.focusedPaneId else {
            herdrPanelOpenerTrace("workspace: no focused pane in newly-created workspace \(workspace.id)")
            return
        }
        guard let exec = HerdrLocalBinary.resolve() else {
            herdrPanelOpenerTrace("workspace: missing herdr-cmux binary")
            presentMissingLocalBinaryAlert(path: HerdrLocalBinary.userInstallPath)
            return
        }
        Task { @MainActor in
            HostHealthStore.shared.reportChecking(hostId: host.id)
            let isRemote: Bool = {
                if case .sshStdio = host.transport { return true }
                return false
            }()
            do {
                try await openLocalhostWorkspaceImpl(
                    host: host,
                    exec: exec,
                    rootPaneId: focusedPane,
                    workspace: workspace,
                    requestedWorkspaceId: requestedWorkspaceId,
                    preExistingPanelIds: preExistingPanelIds
                )
                HostHealthStore.shared.reportOnline(hostId: host.id)
            } catch HerdrPanelOpenerError.noWorkspaceAvailable {
                // No daemon-side workspace to attach to (and nothing
                // useful in persistence). Silently tear down the
                // placeholder tab we made up front; no alert because
                // this is a normal no-op outcome from AutoReattach.
                herdrPanelOpenerTrace("openWorkspace: nothing to attach for \(host.displayName)")
                tabManager.closeWorkspace(workspace, recordHistory: false)
                HostHealthStore.shared.reportOnline(hostId: host.id)
            } catch {
                herdrPanelOpenerTrace("openWorkspace failed for host \(host.displayName): \(error)")
                let reason = friendlyErrorMessage(error, isRemote: isRemote)
                HostHealthStore.shared.reportOffline(hostId: host.id, reason: reason)
                // Drop the empty cmux workspace we created up front so a
                // failed open doesn't leave the user with a placeholder
                // tab pinned to a dead host.
                tabManager.closeWorkspace(workspace, recordHistory: false)
                presentOpenFailureAlert(host: host, error: error)
            }
        }
    }

    @MainActor
    private static func presentMissingLocalBinaryAlert(path: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "herdr.alert.missingBinary.title",
            defaultValue: "Local cmux agent not found"
        )
        alert.informativeText = String(
            localized: "herdr.alert.missingBinary.message",
            defaultValue: "cmux's local agent isn't bundled with this build.\ncmux can download the right binary from the herdr release for you. Click Install to drop it at \(path)."
        )
        alert.addButton(withTitle: String(
            localized: "herdr.alert.missingBinary.install",
            defaultValue: "Install"
        ))
        alert.addButton(withTitle: String(
            localized: "herdr.alert.missingBinary.dismiss",
            defaultValue: "Cancel"
        ))
        if alert.runModal() == .alertFirstButtonReturn {
            HerdrLocalAgentInstaller.installToUserBin()
        }
    }

    @MainActor
    private static func presentOpenFailureAlert(host: HerdrHost, error: Error) {
        let isRemote: Bool = {
            if case .sshStdio = host.transport { return true }
            return false
        }()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "herdr.alert.openFailed.title",
            defaultValue: "Couldn't open workspace on \(host.displayName)"
        )
        let body = friendlyErrorMessage(error, isRemote: isRemote)
        let technicalDetail = String(describing: error)
        if isRemote {
            alert.informativeText = body + "\n\n" + String(
                localized: "herdr.alert.openFailed.remote.hint",
                defaultValue: "If \(host.displayName) is new, click Install to set up cmux on it."
            )
            alert.addButton(withTitle: String(
                localized: "herdr.alert.openFailed.install",
                defaultValue: "Install on \(host.displayName)"
            ))
            alert.addButton(withTitle: String(
                localized: "herdr.alert.openFailed.dismiss",
                defaultValue: "Dismiss"
            ))
            // Surface the raw error in the expandable accessory so
            // power users can still copy it; hidden by default.
            alert.accessoryView = makeDetailAccessory(technicalDetail)
            if alert.runModal() == .alertFirstButtonReturn {
                HerdrRemoteInstaller.installOnHost(host)
            }
        } else {
            alert.informativeText = body
            alert.addButton(withTitle: String(
                localized: "herdr.alert.openFailed.retry",
                defaultValue: "Retry"
            ))
            alert.addButton(withTitle: String(
                localized: "herdr.alert.openFailed.dismiss",
                defaultValue: "Dismiss"
            ))
            alert.accessoryView = makeDetailAccessory(technicalDetail)
            if alert.runModal() == .alertFirstButtonReturn {
                openWorkspace(host: host)
            }
        }
    }

    /// Translate a HerdrTransportError or generic Error into product
    /// language. Power users still get the raw description in the
    /// alert's expandable detail accessory.
    private static func friendlyErrorMessage(_ error: Error, isRemote: Bool) -> String {
        if let t = error as? HerdrTransportError {
            switch t {
            case .socketConnect(let errno):
                switch errno {
                case 2:  // ENOENT
                    return isRemote
                        ? String(localized: "herdr.err.remote.noSocket",
                                 defaultValue: "Couldn't reach the cmux agent on the remote. It may not be installed yet.")
                        : String(localized: "herdr.err.local.noSocket",
                                 defaultValue: "The local cmux agent isn't running. cmux will retry automatically next time you open a workspace.")
                case 61: // ECONNREFUSED
                    return String(localized: "herdr.err.connRefused",
                                  defaultValue: "The cmux agent isn't accepting connections right now.")
                case 60: // ETIMEDOUT
                    return String(localized: "herdr.err.timeout",
                                  defaultValue: "Timed out talking to the cmux agent.")
                default:
                    return String(localized: "herdr.err.connectGeneric",
                                  defaultValue: "Couldn't connect to the cmux agent (errno \(errno)).")
                }
            case .socketCreate:
                return String(localized: "herdr.err.socketCreate",
                              defaultValue: "Couldn't open a local socket. Check macOS sandbox / app permissions.")
            case .pathTooLong:
                return String(localized: "herdr.err.pathTooLong",
                              defaultValue: "The agent socket path is too long. Try a shorter session name in Advanced settings.")
            case .notConnected:
                return String(localized: "herdr.err.notConnected",
                              defaultValue: "The cmux agent disconnected. cmux will retry automatically.")
            case .alreadyConnected:
                return String(localized: "herdr.err.alreadyConnected",
                              defaultValue: "An existing connection to the cmux agent is still open.")
            case .other(let s):
                return s
            case .socketRead(let errno):
                return String(localized: "herdr.err.socketRead",
                              defaultValue: "Lost connection to the cmux agent (errno \(errno)).")
            case .socketWrite(let errno):
                return String(localized: "herdr.err.socketWrite",
                              defaultValue: "Couldn't send data to the cmux agent (errno \(errno)).")
            case .eof:
                return String(localized: "herdr.err.eof",
                              defaultValue: "The cmux agent closed the connection.")
            }
        }
        if let s = error as? DaemonSpawnCoordinator.SpawnError {
            switch s {
            case .daemonExitedDuringStartup(let status, let stderr):
                if stderr.isEmpty {
                    return String(localized: "herdr.err.localCrash",
                                  defaultValue: "The local cmux agent quit during startup (status \(status)).")
                }
                return String(localized: "herdr.err.localCrashWithDetail",
                              defaultValue: "The local cmux agent quit during startup: \(stderr)")
            case .socketDidNotAppear:
                return String(localized: "herdr.err.localNoSocket",
                              defaultValue: "The local cmux agent didn't open its socket in time.")
            }
        }
        return String(describing: error)
    }

    /// NSAlert accessory holding the raw technical error inside an
    /// NSDisclosureButton-driven container. Collapsed by default so
    /// typical users see only the friendly headline + buttons; clicking
    /// "Show details" reveals the monospaced original error for power
    /// users / bug reports.
    @MainActor
    private static func makeDetailAccessory(_ text: String) -> NSView {
        let containerWidth: CGFloat = 360
        let triangleHeight: CGFloat = 18
        let scrollHeight: CGFloat = 80

        let detail = NSTextView()
        detail.string = text
        detail.isEditable = false
        detail.isSelectable = true
        detail.drawsBackground = false
        detail.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.textContainerInset = NSSize(width: 4, height: 4)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: scrollHeight))
        scroll.documentView = detail
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.isHidden = true

        let toggle = NSButton(frame: NSRect(x: 0, y: scrollHeight, width: containerWidth, height: triangleHeight))
        toggle.bezelStyle = .disclosure
        toggle.title = ""
        toggle.imagePosition = .imageOnly
        toggle.state = .off
        let label = NSTextField(labelWithString: String(
            localized: "herdr.alert.detail.toggle",
            defaultValue: "Show details"
        ))
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(
            x: triangleHeight + 2,
            y: scrollHeight + 2,
            width: containerWidth - triangleHeight - 4,
            height: triangleHeight - 4
        )

        let container = NSView(frame: NSRect(
            x: 0, y: 0, width: containerWidth, height: scrollHeight + triangleHeight
        ))
        container.addSubview(scroll)
        container.addSubview(toggle)
        container.addSubview(label)

        // Shrink to just the toggle when collapsed; expand to full size
        // when shown. NSAlert sizes itself to the accessory frame.
        let collapsedFrame = NSRect(x: 0, y: 0, width: containerWidth, height: triangleHeight)
        let expandedFrame = container.frame
        container.setFrameSize(collapsedFrame.size)
        // Push toggle/label down to y=0 in collapsed state.
        toggle.frame.origin.y = 0
        label.frame.origin.y = 2
        scroll.isHidden = true

        let target = DisclosureToggleHandler { sender in
            let expanding = sender.state == .on
            scroll.isHidden = !expanding
            container.setFrameSize(expanding ? expandedFrame.size : collapsedFrame.size)
            toggle.frame.origin.y = expanding ? scrollHeight : 0
            label.frame.origin.y = (expanding ? scrollHeight : 0) + 2
            // Ask the alert to relayout around the new accessory size.
            container.window?.layoutIfNeeded()
        }
        toggle.target = target
        toggle.action = #selector(DisclosureToggleHandler.handle(_:))
        // Keep the handler alive for the alert's lifetime.
        objc_setAssociatedObject(container, &disclosureHandlerKey, target, .OBJC_ASSOCIATION_RETAIN)

        return container
    }

    private static func openLocalhostWorkspaceImpl(
        host: HerdrHost,
        exec: String,
        rootPaneId: PaneID,
        workspace: Workspace,
        requestedWorkspaceId: String? = nil,
        preExistingPanelIds: Set<UUID> = []
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
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = String(
                    localized: "herdr.alert.incompatible.title",
                    defaultValue: "cmux agent incompatible"
                )
                alert.informativeText = String(
                    localized: "herdr.alert.incompatible.message",
                    defaultValue: "\(host.displayName) is running an older cmux agent. Reinstall the agent on this computer, then try again."
                )
                alert.alertStyle = .warning
                alert.accessoryView = makeDetailAccessory(reason)
                alert.addButton(withTitle: String(
                    localized: "herdr.alert.incompatible.reinstall",
                    defaultValue: "Reinstall"
                ))
                alert.addButton(withTitle: String(
                    localized: "herdr.alert.incompatible.dismiss",
                    defaultValue: "Dismiss"
                ))
                if alert.runModal() == .alertFirstButtonReturn {
                    if case .sshStdio = host.transport {
                        HerdrRemoteInstaller.installOnHost(host)
                    } else {
                        HerdrLocalAgentInstaller.installToUserBin()
                    }
                }
            }
            return
        case .unreachable(let reason):
            // Transport-level failure: don't tell the user to reinstall
            // (binary may be fine). Daemon likely crashed or socket
            // went stale. Offer Retry instead.
            herdrPanelOpenerTrace("workspace: agent unreachable — \(reason)")
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = String(
                    localized: "herdr.alert.unreachable.title",
                    defaultValue: "Couldn't reach the cmux agent on \(host.displayName)"
                )
                alert.informativeText = String(
                    localized: "herdr.alert.unreachable.message",
                    defaultValue: "The agent stopped responding. cmux can try again — the agent will be restarted automatically if it's missing."
                )
                alert.alertStyle = .warning
                alert.accessoryView = makeDetailAccessory(reason)
                alert.addButton(withTitle: String(
                    localized: "herdr.alert.unreachable.retry",
                    defaultValue: "Retry"
                ))
                alert.addButton(withTitle: String(
                    localized: "herdr.alert.unreachable.dismiss",
                    defaultValue: "Dismiss"
                ))
                if alert.runModal() == .alertFirstButtonReturn {
                    // Retry path runs from inside openLocalhostWorkspaceImpl
                    // which doesn't carry the original reuseCmuxWorkspaceId
                    // hint. Falling back to fresh-attach is acceptable here:
                    // the reuse codepath collapsed the stale tree before we
                    // reached the unreachable alert, so nothing to adopt.
                    openWorkspace(
                        host: host,
                        requestedWorkspaceId: requestedWorkspaceId,
                        reuseCmuxWorkspaceId: nil
                    )
                }
            }
            return
        }

        // Daemon's API socket is one-shot per connection (see
        // herdr/src/api/mod.rs handle_connection — reads exactly one
        // line then returns). Every helper below opens a fresh
        // transport via HerdrOneShotRPC.request; do NOT keep a single
        // HerdrApiClient open across multiple `request` calls — the
        // second one would EPIPE.
        let workspaceId: String
        let activeTabId: String
        var workspaceLabel: String? = nil
        if let requested = requestedWorkspaceId {
            // Sidebar / explicit-id path: skip auto-select. We still
            // need active_tab_id, fetched via workspace.get.
            let wsResp = try await HerdrOneShotRPC.request(
                host: host,
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
            workspaceLabel = wsInfo["label"] as? String
            herdrPanelOpenerTrace("workspace: opening explicit \(workspaceId) tab=\(activeTabId) label=\(workspaceLabel ?? "(nil)")")
        } else if let persisted = HerdrPersistence.shared
                    .entries(forHostSession: host.sessionName).first,
                  let resolved = await Self.resolvePersistedWorkspace(
                      host: host,
                      sessions: sessions,
                      persisted: persisted
                  ) {
            workspaceId = resolved.workspaceId
            activeTabId = resolved.tabId
            // Pull the daemon's current label for the persisted
            // workspace so the cmux tab title reflects rename done
            // by another client between sessions.
            if let labelResp = try? await HerdrOneShotRPC.request(
                host: host,
                method: "workspace.get",
                params: ["workspace_id": workspaceId]
            ),
               let labelInfo = labelResp["workspace"] as? [String: Any],
               let label = labelInfo["label"] as? String {
                workspaceLabel = label
            }
            herdrPanelOpenerTrace("workspace: reusing persisted \(workspaceId) tab=\(activeTabId) label=\(workspaceLabel ?? "(nil)")")
        } else if let stale = HerdrPersistence.shared
                    .entries(forHostSession: host.sessionName).first {
            // Only the FIRST persisted entry was stale (couldn't be
            // resolved against current sessions). Drop just that
            // entry — other persisted bindings for this host are
            // still potentially valid and will be picked up by
            // auto-reattach next launch.
            HerdrPersistence.shared.clearOne(
                host: host,
                workspaceId: stale.workspaceId,
                tabId: stale.tabId
            )
            herdrPanelOpenerTrace("workspace: cleared stale persisted entry \(stale.workspaceId)/\(stale.tabId) for \(host.sessionName)")
            if let first = sessions.first {
                workspaceId = first.name
                guard let resp = try? await HerdrOneShotRPC.request(
                    host: host,
                    method: "workspace.get",
                    params: ["workspace_id": first.name]
                ),
                let wsInfo = resp["workspace"] as? [String: Any],
                let firstActiveTabId = wsInfo["active_tab_id"] as? String else {
                    herdrPanelOpenerTrace("workspace: fallback workspace.get failed for \(first.name)")
                    throw HerdrPanelOpenerError.noWorkspaceAvailable
                }
                activeTabId = firstActiveTabId
                workspaceLabel = wsInfo["label"] as? String
                herdrPanelOpenerTrace("workspace: fallback to first \(workspaceId) tab=\(activeTabId) label=\(workspaceLabel ?? "(nil)")")
            } else {
                // Persistence pointed at a workspace that no longer
                // exists on the daemon AND there's nothing else to
                // attach to. Bail with an error so the caller's catch
                // handler tears down the placeholder cmux tab it
                // created up front; otherwise AutoReattach leaves the
                // user with an empty 'auto-created' workspace tab even
                // after `herdr session delete cmux`.
                herdrPanelOpenerTrace("workspace: no sessions to fall back to — aborting reattach")
                throw HerdrPanelOpenerError.noWorkspaceAvailable
            }
        } else if let first = sessions.first {
            // Fall back: first existing workspace, its active tab.
            let wsResp = try await HerdrOneShotRPC.request(
                host: host,
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
            workspaceLabel = wsInfo["label"] as? String
        } else {
            // No existing workspace — create one. Pass cwd so the
            // initial pane spawns in the user's home directory instead
            // of the daemon's working directory ("/" when launched
            // headless).
            let r = try await HerdrOneShotRPC.request(
                host: host,
                method: "workspace.create",
                params: [
                    "focus": false,
                    "label": "cmux-workspace",
                    "cwd": NSHomeDirectory(),
                ]
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
            workspaceLabel = ws["label"] as? String
        }

        // Backfill the placeholder workspace's title with the daemon's
        // label so the sidebar shows 'test' instead of 'Terminal N'
        // after openWorkspace creates the tab up front (before this
        // function knows which daemon workspace it attaches to).
        // Skip if the user already gave the cmux workspace a custom
        // title — local rename wins over an automatic daemon-label
        // backfill.
        if let label = workspaceLabel?.trimmingCharacters(in: .whitespaces),
           !label.isEmpty,
           workspace.customTitle?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
            await MainActor.run {
                workspace.setCustomTitle(label)
            }
        }

        // Map herdr pane id -> terminal id from pane.list, so the
        // executor's paneFactory can spin up display clients pointed
        // at the right terminal.
        let panesResp = try await HerdrOneShotRPC.request(
            host: host,
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

        let layoutResp = try await HerdrOneShotRPC.request(
            host: host,
            method: "layout.snapshot",
            params: ["workspace_id": workspaceId, "tab_id": activeTabId]
        )
        let tree = try HerdrApiClient.decodeLayoutTree(from: layoutResp)
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
        HerdrPersistence.shared.record(
            host: host,
            workspaceId: workspaceId,
            tabId: activeTabId,
            cmuxWorkspaceId: workspace.id
        )

        // Close the local TerminalPanel(s) that Workspace.init created
        // before the herdr binding existed. wireHerdrBackedPanel just
        // added a new TerminalPanel in the same pane; without this
        // cleanup the user sees two tabs side-by-side (the local stub
        // + the herdr panel) while herdr's TUI shows one pane. The
        // herdr panel is the only new panel, so anything in
        // preExistingPanelIds that's still alive is stale.
        let stalePanelIds = preExistingPanelIds.intersection(workspace.panels.keys)
        for panelId in stalePanelIds {
            _ = workspace.closePanel(panelId, force: true)
        }
    }

    /// Verify the persisted workspace+tab still exists on the daemon
    /// before reusing it. If listSessions doesn't have the workspace,
    /// or workspace.get returns a different active tab, we fall back
    /// to the first available.
    private static func resolvePersistedWorkspace(
        host: HerdrHost,
        sessions: [DaemonSession],
        persisted: HerdrPersistence.Entry
    ) async -> (workspaceId: String, tabId: String)? {
        guard sessions.contains(where: { $0.name == persisted.workspaceId }) else {
            return nil
        }
        guard let resp = try? await HerdrOneShotRPC.request(
            host: host,
            method: "workspace.get",
            params: ["workspace_id": persisted.workspaceId]
        ) else {
            return nil
        }
        guard let wsInfo = resp["workspace"] as? [String: Any] else {
            return nil
        }
        guard let tabsResp = try? await HerdrOneShotRPC.request(
            host: host,
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
        host: HerdrHost
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
                host: host
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
                host: host
            )
        }
    }

    private static func schedulePanelResize(
        panelId: UUID,
        surface: ghostty_surface_t,
        paneId: String,
        host: HerdrHost
    ) {
        let debounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            forwardPanelSize(
                panelId: panelId,
                surface: surface,
                paneId: paneId,
                host: host
            )
        }
        HerdrPanelRegistry.shared.setResizeDebounceTask(panelId: panelId, task: debounce)
    }

    private static func forwardPanelSize(
        panelId: UUID,
        surface: ghostty_surface_t,
        paneId: String,
        host: HerdrHost
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
        // Route through the host's transport (local UDS or SSH stdio)
        // via HerdrOneShotRPC. The previous direct AF_UNIX socket
        // open hardcoded a local path, which broke for SSH hosts —
        // the daemon's socket lives on the *remote* filesystem.
        Task.detached(priority: .userInitiated) {
            await HerdrOneShotRPC.send(
                host: host,
                method: "pane.resize",
                params: [
                    "pane_id": paneId,
                    "cols": Int(size.columns),
                    "rows": Int(size.rows),
                    "cell_width_px": Int(size.cell_width_px),
                    "cell_height_px": Int(size.cell_height_px),
                ]
            )
            await MainActor.run {
                herdrPanelOpenerTrace("send: pane.resize \(size.columns)x\(size.rows) via \(host.displayName) ok")
            }
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

private var disclosureHandlerKey: UInt8 = 0

/// Plain Cocoa target/action sink so we can use a closure-style
/// callback for NSButton without subclassing each time.
private final class DisclosureToggleHandler: NSObject {
    let block: (NSButton) -> Void
    init(_ block: @escaping (NSButton) -> Void) { self.block = block }
    @objc func handle(_ sender: Any?) {
        if let b = sender as? NSButton { block(b) }
    }
}
