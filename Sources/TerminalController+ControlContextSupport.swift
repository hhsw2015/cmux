import CmuxControlSocket
import Foundation

// P41: Fork-side support shims for the upstream Coordinator extensions.
// Provides typed routing helpers (`resolveTabManager(routing:)`) the
// extensions assume, plus a few internal accessor wrappers around the
// fork's `private` v2 methods.
extension TerminalController {
    func resolveTabManager(routing: ControlRoutingSelectors) -> TabManager? {
        if routing.hasWindowIDParam {
            guard let windowId = routing.windowID else { return nil }
            return AppDelegate.shared?.tabManagerFor(windowId: windowId)
        }
        if let groupId = routing.groupID,
           let tm = v2LocateTabManager(forGroupId: groupId) {
            return tm
        }
        if let workspaceId = routing.workspaceID,
           let tm = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) {
            return tm
        }
        if let surfaceId = routing.surfaceID,
           let tm = AppDelegate.shared?.locateSurface(surfaceId: surfaceId)?.tabManager {
            return tm
        }
        if let paneId = routing.paneID,
           let tm = v2LocatePane(paneId)?.tabManager {
            return tm
        }
        return tabManager ?? AppDelegate.shared?.currentScriptableMainWindow()?.tabManager
    }
}
