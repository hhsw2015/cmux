import AppKit
import CmuxControlSocket
import CmuxPanes
import Bonsplit
import Foundation

// Fork-only TerminalController adapters after the upstream merge.
extension TerminalController {
    // controlTabManager lives in TerminalController+RemoteTmuxControlTopology.swift
    // controlSystemTreeWorkspaceNode lives in TerminalController+ControlSystemContext.swift

    /// Pane / surface ref refresh hook. Upstream lacks the fork's V2-aware
    /// pane/surface remap step; the mirror bookkeeping is now handled inline by
    /// `RemoteTmuxSessionMirror+WindowReconciliation`, so these are no-ops.
    nonisolated func v2RefreshRemoteTmuxAwarePaneAndSurfaceRefs(_ params: [String: Any]) {}
    nonisolated func v2RefreshRemoteTmuxAwarePaneAndSurfaceRefs(workspace: Workspace) {}

    static func remoteTmuxControlPaneRemovalHandler() -> @MainActor (PaneID, UUID?) -> Void { { _, _ in } }
    static func remoteTmuxControlSurfaceRemovalHandler() -> @MainActor (UUID) -> Void { { _ in } }
}

/// Fork adapter for the `remote.tmux.attach` / `remote.tmux.window` V2 socket
/// commands. Preserves the pre-merge `attachHost` contract by driving the
/// surviving controller primitives (`transport`, `mirrorSessions`,
/// `createMainWindow`) directly and returning the shared
/// ``RemoteTmuxAttachOutcome`` type so V2 responses stay consistent.
extension RemoteTmuxController {
    func attachHost(
        host: RemoteTmuxHost,
        windowTarget: RemoteTmuxAttachWindowTarget,
        activate: Bool
    ) async throws -> RemoteTmuxAttachOutcome {
        guard let appDelegate = await MainActor.run(body: { AppDelegate.shared }) else {
            throw RemoteTmuxError.unreachable("app not ready")
        }

        // Resolve the destination window up front (existing mirror wins, then
        // caller intent, then active window for contextual routing).
        let resolvedWindowId: UUID? = await MainActor.run {
            let existing = self.windowRegistry.windowId(forHostHash: host.connectionHash)
            let activeId = (NSApp.keyWindow ?? NSApp.mainWindow)
                .flatMap { $0.identifier?.rawValue }
                .flatMap { UUID(uuidString: $0) }
            return windowTarget.resolve(
                existingMirrorWindowID: existing,
                activeWindowID: activeId,
                isLive: { id in appDelegate.tabManagerFor(windowId: id) != nil }
            )
        }

        // Discover the host's mirror sessions. If SSH bombs with an interactive
        // prompt, ask the caller (the CLI) to auth in its real tty.
        let transport = await MainActor.run(body: { self.transport(for: host) })
        let createIfEmpty = resolvedWindowId == nil && windowTarget != .unresolvedExplicitWindow
        let sessions: [RemoteTmuxSession]
        do {
            sessions = try await transport.discoverMirrorSessions(createIfEmpty: createIfEmpty)
        } catch let error as RemoteTmuxError {
            if case .commandFailed(_, let stderr) = error,
               RemoteTmuxSSHTransport.indicatesInteractiveRetryWillHelp(stderr) {
                return .authRequired(sshArgv: host.interactiveAuthInvocation())
            }
            throw error
        }

        guard !sessions.isEmpty else {
            throw RemoteTmuxError.unreachable("no tmux sessions on \(host.destination)")
        }

        // Mirror into the resolved window if there is one, otherwise open a new
        // dedicated window and mirror into it.
        let result: (UUID, [UUID]) = try await MainActor.run {
            if let windowId = resolvedWindowId,
               let manager = appDelegate.tabManagerFor(windowId: windowId) {
                let priorIds = Set(manager.tabs.map(\.id))
                self.mirrorSessions(sessions, host: host, into: manager)
                let newIds = manager.tabs.map(\.id).filter { !priorIds.contains($0) }
                if activate, let window = appDelegate.mainWindow(for: windowId) {
                    window.makeKeyAndOrderFront(nil)
                }
                return (windowId, newIds)
            }

            let newWindowId = appDelegate.createMainWindow(shouldActivate: activate)
            guard let manager = appDelegate.tabManagerFor(windowId: newWindowId) else {
                throw RemoteTmuxError.unreachable("could not create window for \(host.destination)")
            }
            self.windowRegistry.bind(host: host, windowId: newWindowId)
            let bootstrapId = manager.tabs.first?.id
            self.mirrorSessions(sessions, host: host, into: manager)
            let mirroredIds = manager.tabs.map(\.id).filter { $0 != bootstrapId }
            if let bootstrapId,
               manager.tabs.count > 1,
               let bootstrap = manager.tabs.first(where: { $0.id == bootstrapId }),
               !bootstrap.isRemoteTmuxMirror {
                manager.closeWorkspace(bootstrap, recordHistory: false)
            }
            return (newWindowId, mirroredIds)
        }

        return .mirrored(windowId: result.0, workspaceIds: result.1)
    }
}
