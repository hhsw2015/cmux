import AppKit
import Foundation

/// User-facing entry points for killing herdr resources from cmux.
/// All actions confirm before destruction since they tear down
/// processes (not detach — that path is automatic via tmux semantics).
/// Round-robin pointer for `jumpToNextBlockedHerdrWorkspace` so
/// repeated invocations cycle through every blocked workspace
/// instead of always re-attaching the first one.
@MainActor
private var herdrJumpCursor: Int = 0

@MainActor
enum HerdrJumpCommands {
    /// Find the next blocked workspace across all hosts and open it.
    /// Cycles through every blocked workspace before wrapping. No-op
    /// (with beep) when nothing is blocked.
    static func jumpToNextBlockedWorkspace() {
        var candidates: [(HerdrHost, HerdrWorkspaceSummary)] = []
        for host in HostRegistry.shared.hosts {
            for ws in HerdrWorkspaceListStore.shared.workspaces(forHost: host)
            where ws.agentStatus?.lowercased() == "blocked" {
                candidates.append((host, ws))
            }
        }
        guard !candidates.isEmpty else {
            NSSound.beep()
            cmuxDebugLog("herdr.jump: no blocked workspaces")
            return
        }
        let idx = herdrJumpCursor % candidates.count
        herdrJumpCursor = (idx + 1) % candidates.count
        let (host, ws) = candidates[idx]
        cmuxDebugLog("herdr.jump: -> \(host.displayName)/\(ws.workspaceId)")
        HerdrPanelOpener.openWorkspace(host: host, workspaceId: ws.workspaceId)
    }
}

@MainActor
enum HerdrKillCommands {
    /// Identify the currently focused cmux pane's herdr binding (if
    /// any) and offer to fire `workspace.close` against the matching
    /// herdr workspace. No-op when the focused pane isn't herdr-backed.
    static func killCurrentWorkspace() {
        guard let appDelegate = AppDelegate.shared,
              let tabManager = appDelegate.tabManager,
              let workspace = tabManager.tabs.first(where: { $0.id == tabManager.selectedTabId })
                ?? tabManager.tabs.first,
              let focused = workspace.bonsplitController.focusedPaneId,
              let binding = HerdrTabRegistry.shared.binding(forCmuxPaneId: focused.id)
        else {
            NSSound.beep()
            cmuxDebugLog("herdr.kill: no herdr binding under focused pane")
            return
        }

        let host = binding.host
        let workspaceId = binding.workspaceId

        let alert = NSAlert()
        alert.messageText = String(
            localized: "herdr.kill.alert.title",
            defaultValue: "Close current workspace?"
        )
        alert.informativeText = String(
            localized: "herdr.kill.alert.message",
            defaultValue: "All processes in this workspace on \(host.displayName) will be terminated."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(
            localized: "herdr.kill.alert.confirm",
            defaultValue: "Kill"
        ))
        alert.addButton(withTitle: String(
            localized: "herdr.kill.alert.cancel",
            defaultValue: "Cancel"
        ))

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task.detached {
            await HerdrOneShotRPC.send(
                host: host,
                method: "workspace.close",
                params: ["workspace_id": workspaceId]
            )
            try? await Task.sleep(nanoseconds: 250_000_000)
            await HerdrWorkspaceListStore.shared.refresh(host: host)
        }
    }
}
