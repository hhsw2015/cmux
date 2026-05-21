import Foundation

/// Bidirectional bridge for workspace + tab focus changes between
/// cmux's TabManager.selectedTabId and the daemon's active workspace /
/// active tab.
///
/// Outbound: when cmux's user picks a sidebar entry, fire
/// `workspace.focus` (and, for herdr-backed workspaces, `tab.focus`)
/// so the TUI follows along.
///
/// Inbound: when the daemon broadcasts `workspace_focused` /
/// `tab_focused`, switch cmux's selectedTabId to the matching binding
/// — without echoing back through the outbound path.
///
/// Echo suppression: a `lastSent` per host plus an
/// `applyingRemote` flag bracket inbound writes so the outbound hook
/// is a no-op while we're materializing a remote event.
@MainActor
final class HerdrWorkspaceFocusSync {
    static let shared = HerdrWorkspaceFocusSync()

    private var lastSentWorkspace: [UUID: String] = [:]
    private var lastSentTab: [UUID: String] = [:]
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

        if lastSentWorkspace[host.id] != workspaceId {
            pendingWorkspace[host.id]?.cancel()
            let task = Task { [host] in
                try? await Task.sleep(nanoseconds: 60_000_000)
                if Task.isCancelled { return }
                await HerdrOneShotRPC.send(
                    host: host,
                    method: "workspace.focus",
                    params: ["workspace_id": workspaceId]
                )
            }
            pendingWorkspace[host.id] = task
            lastSentWorkspace[host.id] = workspaceId
        }

        if lastSentTab[host.id] != tabId {
            pendingTab[host.id]?.cancel()
            let task = Task { [host] in
                try? await Task.sleep(nanoseconds: 60_000_000)
                if Task.isCancelled { return }
                await HerdrOneShotRPC.send(
                    host: host,
                    method: "tab.focus",
                    params: ["tab_id": tabId]
                )
            }
            pendingTab[host.id] = task
            lastSentTab[host.id] = tabId
        }
    }

    /// Daemon broadcast `workspace_focused` — switch cmux to the
    /// matching binding so the sidebar selection follows.
    func applyRemoteWorkspaceFocus(host: HerdrHost, herdrWorkspaceId: String) {
        if lastSentWorkspace[host.id] == herdrWorkspaceId { return }
        guard let cmuxWorkspaceId = HerdrTabRegistry.shared.cmuxWorkspaceId(
            forHerdrWorkspace: herdrWorkspaceId, host: host
        ) else { return }
        guard let tabManager = AppDelegate.shared?.tabManager else { return }
        guard tabManager.selectedTabId != cmuxWorkspaceId else {
            lastSentWorkspace[host.id] = herdrWorkspaceId
            return
        }
        lastSentWorkspace[host.id] = herdrWorkspaceId
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
        if lastSentTab[host.id] == herdrTabId { return }
        let target = HerdrTabRegistry.shared.allBindings.first {
            $0.host.id == host.id && $0.tabId == herdrTabId
        }
        guard let binding = target, let cmuxWorkspaceId = binding.workspace?.id else {
            return
        }
        guard let tabManager = AppDelegate.shared?.tabManager else { return }
        guard tabManager.selectedTabId != cmuxWorkspaceId else {
            lastSentTab[host.id] = herdrTabId
            return
        }
        lastSentTab[host.id] = herdrTabId
        applyingRemote = true
        defer { applyingRemote = false }
        if let workspace = tabManager.tabs.first(where: { $0.id == cmuxWorkspaceId }) {
            tabManager.selectWorkspace(workspace)
        }
    }
}
