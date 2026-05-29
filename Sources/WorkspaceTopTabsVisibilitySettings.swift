import Bonsplit
import Foundation

/// Controls when the workspace top tab bar is shown above the layout.
///
/// The bar duplicates information also surfaced inside the panel title for
/// single-tab workspaces. `auto` hides it until a second top tab is created
/// so the panel title is the only chrome line; `always` keeps the upstream
/// behavior; `never` is for users who already manage layout via the sidebar.
enum WorkspaceTopTabsVisibility: String, CaseIterable, Sendable {
    case always
    case auto
    case never

    var bonsplitVisibility: TabBarVisibility {
        switch self {
        case .always:
            return .always
        case .auto:
            return .multipleTabs
        case .never:
            // Bonsplit has no first-class hidden mode but
            // .multipleTabs reduces to "0 or 1 tab => hidden". We pin
            // top tabs to a single tab in this mode so the bar never
            // shows.
            return .multipleTabs
        }
    }
}

enum WorkspaceTopTabsVisibilitySettings {
    static let key = "workspaceTopTabsVisibility"
    static let defaultValue: WorkspaceTopTabsVisibility = .auto

    static func current(defaults: UserDefaults = .standard) -> WorkspaceTopTabsVisibility {
        guard let raw = defaults.string(forKey: key),
              let value = WorkspaceTopTabsVisibility(rawValue: raw) else {
            return defaultValue
        }
        return value
    }
}
