import CmuxTerminal
import Foundation

extension TerminalSurface {
    @MainActor
    func foregroundProcessHasChildren() -> Bool { false }
}

extension TerminalSurface {
    @MainActor
    func stageHibernationRestore(scrollback: Any? = nil, workingDirectory: String? = nil) {}
    @MainActor
    func prepareHibernationResume(initialInput: String? = nil) {}
    @MainActor
    func suspendRuntimeSurfaceForHibernation(reason: String) {}
}
