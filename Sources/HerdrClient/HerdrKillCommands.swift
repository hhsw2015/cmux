import AppKit
import Foundation

/// User-facing entry points for killing herdr resources from cmux.
/// All actions confirm before destruction since they tear down
/// processes (not detach — that path is automatic via tmux semantics).
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
            defaultValue: "Kill current Herdr workspace?"
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
