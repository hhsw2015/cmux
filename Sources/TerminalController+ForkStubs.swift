import CmuxControlSocket
import Foundation

// ponytail: fork-only TerminalController stubs after upstream merge
extension TerminalController {
    var controlTabManager: TabManager? { tabManager }
    func controlSystemTreeWorkspaceNode(routing: ControlRoutingSelectors) -> Any? { nil }
    nonisolated func v2RefreshRemoteTmuxAwarePaneAndSurfaceRefs(_ params: [String: Any]) {}
}


// ponytail: fork-only RemoteTmuxController.attachHost stub after upstream merge
extension RemoteTmuxController {
    enum WindowTarget { case current, dedicatedNewWindow }
    enum AttachOutcome {
        case mirrored(UUID, [UUID])
        case authRequired([String])
    }
    func attachHost(host: RemoteTmuxHost, windowTarget: WindowTarget, activate: Bool) async throws -> AttachOutcome {
        // ponytail: not wired up - returns empty mirrored
        return .mirrored(UUID(), [])
    }
}
