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
// Best-effort: failures past tab.create roll back the daemon-side
// Tab so we don't leak orphans. Caller doesn't await.

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
        let workspaceUUID = workspace.id

        Task.detached { [host, workspaceId, workspaceUUID, weak workspace] in
            await mirror(
                workspace: workspace,
                workspaceUUID: workspaceUUID,
                host: host,
                herdrWorkspaceId: workspaceId,
                cmuxLayoutTabId: layoutTabId,
                placeholderPaneId: rootPaneId
            )
        }
    }

    private static func mirror(
        workspace: Workspace?,
        workspaceUUID: UUID,
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

        // Past this point any failure must roll back the daemon-side
        // tab so we don't leak orphans. cleanup() fires tab.close +
        // logs.
        let cleanup: () async -> Void = { [host, herdrWorkspaceId, newTabId] in
            await HerdrOneShotRPC.send(
                host: host,
                method: "tab.close",
                params: [
                    "workspace_id": herdrWorkspaceId,
                    "tab_id": newTabId,
                ]
            )
        }

        // Discover the default pane the daemon created inside the new
        // tab/window. cmux-tmux's tmux backend always creates one
        // initial pane via `tmux new-window`, but tmux pane creation
        // is technically async — retry briefly so we don't race the
        // first panes.list against pane materialization.
        let listParams: [String: Any] = [
            "workspace_id": herdrWorkspaceId,
            "tab_id": newTabId,
        ]
        var firstPane: [String: Any]? = nil
        var lastListError: Error? = nil
        for attempt in 0..<5 {
            do {
                let listResp = try await HerdrOneShotRPC.request(
                    host: host,
                    method: "panes.list",
                    params: listParams
                )
                if let panes = listResp["panes"] as? [[String: Any]],
                   let candidate = panes.first {
                    firstPane = candidate
                    break
                }
            } catch {
                lastListError = error
            }
            if attempt < 4 {
                try? await Task.sleep(nanoseconds: UInt64(80_000_000) * UInt64(attempt + 1))
            }
        }

        guard let firstPane,
              let herdrPaneId = firstPane["id"] as? String,
              let terminalId = firstPane["terminal_id"] as? String
        else {
            await logFailure(
                stage: "panes.list",
                error: lastListError ?? BridgeError.missingPaneInfo,
                startedAt: startedAt,
                host: host
            )
            await cleanup()
            return
        }

        guard let exec = await MainActor.run(body: { HerdrLocalBinary.resolve() }) else {
            await logFailure(stage: "resolveBinary", error: BridgeError.missingBinary, startedAt: startedAt, host: host)
            await cleanup()
            return
        }

        guard let workspace else {
            await logFailure(stage: "workspaceGone", error: BridgeError.workspaceDeallocated, startedAt: startedAt, host: host)
            await cleanup()
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
            await cleanup()
            return
        }

        // After wireHerdrBackedPanel splits and adds the daemon-backed
        // pane next to the placeholder, close the original local pane
        // so the user sees a single daemon-backed pane in the new
        // layout tab.
        await MainActor.run { [weak workspace] in
            guard let workspace else { return }
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
                "herdr.layoutTab.bridge ok workspace=\(workspaceUUID.uuidString.prefix(5)) "
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
        #if DEBUG
        let durMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        await MainActor.run {
            cmuxDebugLog(
                "herdr.layoutTab.bridge fail stage=\(stage) "
                + "host=\(host.displayName) durMs=\(durMs) error=\(error)"
            )
        }
        #endif
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
    ///
    /// Suppresses pane.close echoes for every herdr pane in the
    /// binding so the surrounding `removeTopLevelLayoutTab` flow
    /// (which closes panes synchronously, triggering HerdrCloseHandler)
    /// doesn't fire pane.close RPCs against an about-to-die window.
    /// tab.close kills the window; pane echoes would race or land on
    /// reused window ids.
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
        for pair in binding.paneBindings.pairs {
            HerdrCloseHandler.suppressNextCloseFor.insert(pair.herdr)
        }
        lastSentTabRenames.removeValue(forKey: bindingKey)
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
        let host = binding.host
        let tabId = binding.tabId
        Task.detached { [host, tabId, trimmed, key] in
            do {
                _ = try await HerdrOneShotRPC.request(
                    host: host,
                    method: "tab.rename",
                    params: [
                        "tab_id": tabId,
                        "name": trimmed,
                    ]
                )
                // Cache only after the daemon acked. A transient
                // failure (SSH drop, daemon restart) leaves the cache
                // stale so the next call retries instead of
                // short-circuiting and stranding tmux/cmux titles
                // out of sync until the tab closes.
                await MainActor.run {
                    lastSentTabRenames[key] = trimmed
                }
            } catch {
                #if DEBUG
                await MainActor.run {
                    cmuxDebugLog("herdr.layoutTab.rename fail tab=\(tabId) error=\(error)")
                }
                #endif
            }
        }
    }

    /// Last-sent title cache to avoid spamming tab.rename when the
    /// panel title sync runs frequently with the same value.
    /// Cleared per-binding in closeMirroredLayoutTab so the cache
    /// can't grow unbounded across long sessions with many tab churns.
    private static var lastSentTabRenames: [UUID: String] = [:]

    private enum BridgeError: Error {
        case missingTabId
        case missingPaneInfo
        case missingBinary
        case workspaceDeallocated
    }
}
