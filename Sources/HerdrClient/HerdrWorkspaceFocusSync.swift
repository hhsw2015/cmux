import Foundation

/// Bidirectional bridge for workspace + tab focus changes between
/// cmux's TabManager.selectedTabId and the daemon's active workspace
/// / active tab.
///
/// Outbound: when cmux's user picks a sidebar entry,
/// `reportLocalSelection` fires `workspace.focus` (and, for
/// herdr-backed workspaces, `tab.focus`) so the TUI follows along.
/// 60 ms debounced per host so a fast click-through doesn't
/// flood the daemon.
///
/// Inbound: when the daemon broadcasts `workspace_focused` /
/// `tab_focused`, switch cmux's selectedTabId to the matching binding
/// — without echoing back through the outbound path.
///
/// Echo suppression uses one mechanism only: `applyingRemote` brackets
/// the inbound mutation so reportLocalSelection's didSet hook
/// short-circuits during the synchronous selectWorkspace call. There
/// is intentionally NO lastSent cache: a previous version had it and
/// rapid user-driven clicks would absorb the daemon's corrective
/// broadcast, leaving cmux desynced from the daemon. Inbound apply
/// is now idempotent (skip if cmux already shows the target
/// workspace) which suffices because the user's outbound RPC, when
/// it round-trips, lands on a cmux state that already matches —
/// no-op apply, no loop.
@MainActor
final class HerdrWorkspaceFocusSync {
    static let shared = HerdrWorkspaceFocusSync()

    private var pendingWorkspace: [UUID: Task<Void, Never>] = [:]
    private var pendingTab: [UUID: Task<Void, Never>] = [:]
    private(set) var applyingRemote: Bool = false

    private init() {}

    /// cmux's selectedTabId changed (user picked a sidebar entry).
    /// If that workspace is herdr-bound, send `workspace.focus` and
    /// `tab.focus` to the daemon so the TUI follows.
    func reportLocalSelection(cmuxWorkspaceId: UUID) {
        guard !applyingRemote else { return }
        guard let binding = HerdrTabRegistry.shared.firstBinding(
            forWorkspaceId: cmuxWorkspaceId
        ) else { return }
        let host = binding.host
        let workspaceId = binding.workspaceId
        let tabId = binding.tabId

        pendingWorkspace[host.id]?.cancel()
        let wsTask = Task { [host] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            if Task.isCancelled { return }
            await HerdrOneShotRPC.send(
                host: host,
                method: "workspace.focus",
                params: ["workspace_id": workspaceId]
            )
        }
        pendingWorkspace[host.id] = wsTask

        pendingTab[host.id]?.cancel()
        let tabTask = Task { [host] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            if Task.isCancelled { return }
            await HerdrOneShotRPC.send(
                host: host,
                method: "tab.focus",
                params: ["tab_id": tabId]
            )
        }
        pendingTab[host.id] = tabTask
    }

    /// Daemon broadcast `workspace_focused` — switch cmux to the
    /// matching binding so the sidebar selection follows.
    func applyRemoteWorkspaceFocus(host: HerdrHost, herdrWorkspaceId: String) {
        guard let cmuxWorkspaceId = HerdrTabRegistry.shared.cmuxWorkspaceId(
            forHerdrWorkspace: herdrWorkspaceId, host: host
        ) else { return }
        guard let tabManager = AppDelegate.shared?.tabManager else { return }
        // Idempotent: if cmux is already on this workspace, the
        // event is either our own echo (no-op) or a redundant
        // re-focus (also no-op).
        guard tabManager.selectedTabId != cmuxWorkspaceId else { return }
        applyingRemote = true
        defer { applyingRemote = false }
        if let workspace = tabManager.tabs.first(where: { $0.id == cmuxWorkspaceId }) {
            tabManager.selectWorkspace(workspace)
        }
    }

    /// Daemon broadcast `tab_focused` — only meaningful when the
    /// active herdr tab in a bound workspace changes. cmux's
    /// "workspace == one herdr tab" mapping means a tab focus is
    /// effectively a workspace focus to the cmux Workspace whose
    /// tabId matches.
    func applyRemoteTabFocus(host: HerdrHost, herdrTabId: String) {
        let target = HerdrTabRegistry.shared.allBindings.first {
            $0.host.id == host.id && $0.tabId == herdrTabId
        }
        guard let binding = target, let cmuxWorkspaceId = binding.workspace?.id else {
            return
        }
        guard let tabManager = AppDelegate.shared?.tabManager else { return }
        guard tabManager.selectedTabId != cmuxWorkspaceId else { return }
        applyingRemote = true
        defer { applyingRemote = false }
        if let workspace = tabManager.tabs.first(where: { $0.id == cmuxWorkspaceId }) {
            tabManager.selectWorkspace(workspace)
        }
    }
}
