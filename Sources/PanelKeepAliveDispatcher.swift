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
            "panel.keepAlive.detach.requested",
            "panel=\(terminalPanel.id.uuidString.prefix(8)) session=\(session)"
        )
#endif
        // Phase 2.2 wires the chokepoint and the dispatcher contract; the
        // actual detach (backend call + move into BackgroundSessionStore +
        // skip panels.removeValue) lands in Phase 2.3 once the full UX is
        // ready. Returning false here keeps current behavior (close +
        // remove) so this phase ships zero behavior change.
        return false
    }
}
