// HerdrLayoutTabBridge — when the user opens a new top-level layout
// tab inside a workspace whose first layout tab is already bound to a
// herdr/cmux-tmux daemon, this bridge mirrors the new layout tab into
// the daemon as a fresh herdr Tab (= tmux window for cmux-tmux).
//
// Flow:
// 1. Cmd+T in cmux creates a local layout tab + 1 placeholder pane.
// 2. Bridge fires tab.create RPC against the host.
// 3. Bridge polls panes.list filtered by the new tab_id to discover
//    the default pane the daemon spawned in that new tab/window.
// 4. Bridge calls wireHerdrBackedPanel against the placeholder pane,
//    causing a split that adds a daemon-backed pane next to it.
// 5. Bridge closes the placeholder pane, leaving a single
//    daemon-backed pane in the new layout tab.
// 6. Bridge registers a fresh HerdrTabBinding tagged with the new
//    cmuxLayoutTabId so HerdrInboundLayoutSync routes mutations into
//    the right BonsplitController.
//
// Best-effort: failures (RPC error, missing pane, wire-fail) leave
// the new layout tab as a local-only fallback. Caller doesn't await.

import Foundation
import Bonsplit

@MainActor
enum HerdrLayoutTabBridge {
    /// Returns true if the workspace has any herdr binding (= it's
    /// daemon-backed and new layout tabs should mirror to the daemon).
    static func isDaemonBackedWorkspace(_ workspace: Workspace) -> Bool {
        HerdrTabRegistry.shared.firstBinding(forWorkspaceId: workspace.id) != nil
    }

    /// Fire-and-forget bridge. Caller does not await; errors are
    /// logged via cmuxDebugLog.
    static func mirrorNewLayoutTabIfBacked(
        workspace: Workspace,
        layoutTabId: UUID,
        rootPaneId: PaneID
    ) {
        guard let originBinding = HerdrTabRegistry.shared.firstBinding(forWorkspaceId: workspace.id) else {
            #if DEBUG
            cmuxDebugLog("herdr.layoutTab.bridge skip workspace=\(workspace.id.uuidString.prefix(5)) reason=no_binding")
            #endif
            return
        }
        let host = originBinding.host
        let workspaceId = originBinding.workspaceId

        Task.detached { [host, workspaceId] in
            await mirror(
                workspace: workspace,
                host: host,
                herdrWorkspaceId: workspaceId,
                cmuxLayoutTabId: layoutTabId,
                placeholderPaneId: rootPaneId
            )
        }
    }

    private static func mirror(
        workspace: Workspace,
        host: HerdrHost,
        herdrWorkspaceId: String,
        cmuxLayoutTabId: UUID,
        placeholderPaneId: PaneID
    ) async {
        let startedAt = Date()
        let createParams: [String: Any] = [
            "workspace_id": herdrWorkspaceId,
            "focus": true,
        ]
        let createResp: [String: Any]
        do {
            createResp = try await HerdrOneShotRPC.request(
                host: host,
                method: "tab.create",
                params: createParams
            )
        } catch {
            await logFailure(stage: "tab.create", error: error, startedAt: startedAt, host: host)
            return
        }

        guard let newTabId = (createResp["tab_id"] as? String)
            ?? ((createResp["tab"] as? [String: Any])?["id"] as? String)
        else {
            await logFailure(stage: "tab.create.parse", error: BridgeError.missingTabId, startedAt: startedAt, host: host)
            return
        }

        // Discover the default pane the daemon created inside the new
        // tab/window. cmux-tmux's tmux backend always creates one
        // initial pane via `tmux new-window`.
        let listParams: [String: Any] = [
            "workspace_id": herdrWorkspaceId,
            "tab_id": newTabId,
        ]
        let listResp: [String: Any]
        do {
            listResp = try await HerdrOneShotRPC.request(
                host: host,
                method: "panes.list",
                params: listParams
            )
        } catch {
            await logFailure(stage: "panes.list", error: error, startedAt: startedAt, host: host)
            return
        }

        guard let panes = listResp["panes"] as? [[String: Any]],
              let firstPane = panes.first,
              let herdrPaneId = firstPane["id"] as? String,
              let terminalId = firstPane["terminal_id"] as? String
        else {
            await logFailure(stage: "panes.list.parse", error: BridgeError.missingPaneInfo, startedAt: startedAt, host: host)
            return
        }

        guard let exec = await MainActor.run(body: { HerdrLocalBinary.resolve() }) else {
            await logFailure(stage: "resolveBinary", error: BridgeError.missingBinary, startedAt: startedAt, host: host)
            return
        }

        do {
            _ = try await HerdrPanelOpener.wireHerdrBackedPanel(
                workspace: workspace,
                cmuxPaneId: placeholderPaneId,
                host: host,
                terminalId: terminalId,
                herdrPaneId: herdrPaneId,
                executablePath: exec,
                socketPath: "",
                focus: true
            )
        } catch {
            await logFailure(stage: "wirePanel", error: error, startedAt: startedAt, host: host)
            return
        }

        // After wireHerdrBackedPanel splits and adds the daemon-backed
        // pane next to the placeholder, close the original local pane
        // so the user sees a single daemon-backed pane in the new
        // layout tab.
        await MainActor.run {
            workspace.markAllTabsForceCloseable()
            if let controller = workspace.bonsplitController(forLayoutTabId: cmuxLayoutTabId) {
                if controller.allPaneIds.contains(placeholderPaneId) {
                    controller.closePane(placeholderPaneId)
                }
            }

            let registry = HerdrPaneBindingRegistry()
            registry.bind(cmuxPaneId: placeholderPaneId.id, herdrPaneId: herdrPaneId)
            let binding = HerdrTabBinding(
                host: host,
                workspaceId: herdrWorkspaceId,
                tabId: newTabId,
                rootCmuxPaneId: placeholderPaneId.id,
                paneBindings: registry,
                workspace: workspace,
                cmuxLayoutTabId: cmuxLayoutTabId
            )
            HerdrTabRegistry.shared.register(key: placeholderPaneId.id, binding: binding)
        }

        let durMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        #if DEBUG
        await MainActor.run {
            cmuxDebugLog(
                "herdr.layoutTab.bridge ok workspace=\(workspace.id.uuidString.prefix(5)) "
                + "layoutTab=\(cmuxLayoutTabId.uuidString.prefix(5)) "
                + "tab=\(newTabId) durMs=\(durMs)"
            )
        }
        #endif
    }

    private static func logFailure(
        stage: String,
        error: Error,
        startedAt: Date,
        host: HerdrHost
    ) async {
        let durMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        await MainActor.run {
            #if DEBUG
            cmuxDebugLog(
                "herdr.layoutTab.bridge fail stage=\(stage) "
                + "host=\(host.displayName) durMs=\(durMs) error=\(error)"
            )
            #endif
            _ = (stage, error, durMs, host)
        }
    }

    /// Find the binding (if any) whose cmuxLayoutTabId matches.
    private static func bindingForLayoutTab(
        workspace: Workspace,
        layoutTabId: UUID
    ) -> HerdrTabBinding? {
        HerdrTabRegistry.shared.allBindings.first { binding in
            binding.workspace?.id == workspace.id && binding.cmuxLayoutTabId == layoutTabId
        }
    }

    /// Close the daemon-side Tab corresponding to a cmux layoutTab,
    /// then drop the registry binding. Best-effort; no-op when the
    /// layoutTab was never daemon-backed.
    static func closeMirroredLayoutTab(
        workspace: Workspace,
        layoutTabId: UUID
    ) {
        guard let binding = bindingForLayoutTab(workspace: workspace, layoutTabId: layoutTabId) else {
            return
        }
        let host = binding.host
        let workspaceId = binding.workspaceId
        let tabId = binding.tabId
        let bindingKey = binding.rootCmuxPaneId
        Task.detached { [host, workspaceId, tabId, bindingKey] in
            await HerdrOneShotRPC.send(
                host: host,
                method: "tab.close",
                params: [
                    "workspace_id": workspaceId,
                    "tab_id": tabId,
                ]
            )
            await MainActor.run {
                HerdrTabRegistry.shared.remove(key: bindingKey)
            }
        }
    }

    /// Mirror a cmux layoutTab title change to the daemon-side Tab name.
    /// No-op when the layoutTab isn't daemon-backed or when the title
    /// hasn't changed since the last sent rename.
    static func renameMirroredLayoutTabIfChanged(
        workspace: Workspace,
        layoutTabId: UUID,
        title: String
    ) {
        guard let binding = bindingForLayoutTab(workspace: workspace, layoutTabId: layoutTabId) else {
            return
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = binding.rootCmuxPaneId
        if lastSentTabRenames[key] == trimmed {
            return
        }
        lastSentTabRenames[key] = trimmed
        let host = binding.host
        let tabId = binding.tabId
        Task.detached { [host, tabId, trimmed] in
            await HerdrOneShotRPC.send(
                host: host,
                method: "tab.rename",
                params: [
                    "tab_id": tabId,
                    "name": trimmed,
                ]
            )
        }
    }

    /// Last-sent title cache to avoid spamming tab.rename when the
    /// panel title sync runs frequently with the same value.
    private static var lastSentTabRenames: [UUID: String] = [:]

    private enum BridgeError: Error {
        case missingTabId
        case missingPaneInfo
        case missingBinary
    }
}
