import CmuxControlSocket
import CmuxPanes
import Bonsplit
import Foundation

// ponytail: fork-only TerminalController stubs after upstream merge
extension TerminalController {
    // ponytail: controlTabManager now in TerminalController+RemoteTmuxControlTopology.swift
    // ponytail: controlSystemTreeWorkspaceNode now in TerminalController+ControlSystemContext.swift
    nonisolated func v2RefreshRemoteTmuxAwarePaneAndSurfaceRefs(_ params: [String: Any]) {}
    nonisolated func v2RefreshRemoteTmuxAwarePaneAndSurfaceRefs(workspace: Workspace) {}
    static func remoteTmuxControlPaneRemovalHandler() -> @MainActor (PaneID, UUID?) -> Void { { _, _ in } }
    static func remoteTmuxControlSurfaceRemovalHandler() -> @MainActor (UUID) -> Void { { _ in } }
}


// ponytail: fork-only RemoteTmuxController.attachHost stub after upstream merge
extension RemoteTmuxController {
    enum AttachOutcome {
        case mirrored(UUID, [UUID])
        case authRequired([String])
    }
    func attachHost(host: RemoteTmuxHost, windowTarget: RemoteTmuxAttachWindowTarget, activate: Bool) async throws -> AttachOutcome {
        return .mirrored(UUID(), [])
    }
}
