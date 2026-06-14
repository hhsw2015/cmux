import Foundation

// ponytail: P43 merge stubs. Upstream lifted these types into packages
// (CmuxPanes, CmuxRemoteSession, CmuxSettings); fork still calls the legacy
// names in TerminalController + a couple of debug/restore paths. Re-export
// thin shims so the merge builds; replace with proper package calls in P44+.

enum SplitEqualizer {
    struct Result {
        var changedPanels: [UUID] = []
        var changedSplits: [UUID] = []
        var didFullyEqualize: Bool = false
    }

    static func equalize(
        in tree: Any,
        controller: Any,
        orientationFilter: Any? = nil
    ) -> Result {
        Result()
    }
}

enum WorkspaceRemoteSessionController {
    enum PortScanKickReason: String, Sendable {
        case manualKick
        case probeFailure
    }
}

import CmuxSettings

enum WorkspaceGroupNewWorkspacePlacementSettings {
    static let defaultValue: WorkspaceGroupNewPlacement = .afterCurrent
    static func resolved() -> WorkspaceGroupNewPlacement? { nil }
}

extension WorkspaceGroupNewPlacement {
    init?(rawString: String) {
        self.init(rawValue: rawString)
    }

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
