import CmuxWorkspaces
import CmuxPanes
import Bonsplit
import CmuxSettings
import Combine
import Foundation

// ponytail: P43 merge stubs. Upstream lifted these types into packages
// (CmuxPanes, CmuxRemoteSession, CmuxSettings); fork still calls the legacy
// names in TerminalController + a couple of debug/restore paths. Re-export
// thin shims so the merge builds; replace with proper package calls in P44+.


enum WorkspaceGroupNewWorkspacePlacementSettings {
    static let defaultValue: WorkspaceGroupNewPlacement = .afterCurrent

    /// Reads the persisted user choice from the workspace-groups catalog setting,
    /// falling back to defaultValue when nothing is stored.
    static func resolved() -> WorkspaceGroupNewPlacement? {
        let key = WorkspaceGroupsCatalogSection().newWorkspacePlacement
        let raw = UserDefaults.standard.string(forKey: key.userDefaultsKey)
        return WorkspaceGroupNewPlacement(rawString: raw) ?? defaultValue
    }
}

extension WorkspaceGroupNewPlacement {
    var settingsDescription: String {
        switch self {
        case .top: return "New workspaces appear at the top of the group."
        case .end: return "New workspaces appear at the end of the group."
        case .afterCurrent: return "New workspaces appear after the current workspace."
        }
    }

    var displayName: String {
        switch self {
        case .top: return "Top"
        case .end: return "End"
        case .afterCurrent: return "After Current"
        }
    }
}




import CmuxCanvas
import CmuxCanvasUI

func shouldRouteTerminalSelectAllToNaturalTextEngine(_ event: Any?) -> Bool { false }

struct TerminalForegroundDirectoryResolver {
    init() {}
    func foregroundDirectory(forTTYName ttyName: String) -> String? { nil }
}

