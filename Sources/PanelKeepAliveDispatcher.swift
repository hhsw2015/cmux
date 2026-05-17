import CMUXZmx
import Foundation

/// Bridges the panel-close chokepoint to the session-persistence
/// keep-alive logic. Phase 2.3 fills in the real detach behavior; for now
/// the dispatcher always returns false so the chokepoint behaves
/// identically to pre-integration.
///
/// Splitting this out keeps Workspace+PanelLifecycle.swift unaware of
/// keep-alive specifics — only the dispatcher (and a single call site)
/// needs to know.
enum PanelKeepAliveDispatcher {
    /// Returns true if the panel was kept alive and should NOT be closed
    /// further by the chokepoint. Returns false to fall through to the
    /// regular `panel.close()` path.
    @MainActor
    static func detachIfKeepAlive(
        panel: (any Panel)?,
        reason: ClosePanelReason
    ) -> Bool {
        guard SessionPersistenceFeatureFlags.effective(.keepAlive) else {
            return false
        }
        guard reason.honorsKeepAlive else { return false }
        guard let terminalPanel = panel as? TerminalPanel else { return false }
        guard terminalPanel.keepAlive else { return false }
        guard let session = terminalPanel.zmxSessionName, !session.isEmpty else {
            // Keep-alive flag is on but the panel was never bound to a
            // session (engine off / user toggled before any sweep ran).
            // Fall through to the regular close — there's nothing to keep.
            return false
        }
#if DEBUG
        SessionPersistenceLog.event(
            "panel.keepAlive.detach",
            "panel=\(terminalPanel.id.uuidString.prefix(8)) session=\(session)"
        )
#endif
        // Move the session metadata into BackgroundSessionStore so the
        // sidebar (Phase 3) and the project save path (Phase 4) can find
        // it after the panel UI is gone.
        BackgroundSessionStore.shared.add(.init(
            id: terminalPanel.id,
            workspaceId: terminalPanel.workspaceId,
            sessionName: session,
            cmd: "",
            dir: terminalPanel.surface.requestedWorkingDirectory ?? "",
            detachedAt: .init()
        ))
        // Detach the daemon-side client asynchronously; the daemon keeps
        // the PTY alive until the session is killed explicitly. We don't
        // wait — the chokepoint must stay synchronous.
        Task.detached(priority: .utility) {
            guard let backend = SessionDaemonResolver.shared.activeDeepBackend() else {
                return
            }
            try? await backend.detachSession(session)
        }
        // We *return false* even though the panel is "kept alive" because
        // the cmux UI still needs to remove the panel from the workspace
        // (the user closed it). The session lives in BackgroundSessionStore
        // until Phase 3 surfaces a "Reattach" UI. Phase 4 will cover the
        // skip-panels.removeValue case for in-place reattach scenarios.
        return false
    }
}
