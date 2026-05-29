import Bonsplit
import Foundation

/// Controls when the workspace top tab bar is shown above the layout.
///
/// Semantics:
/// - `always`: bar is permanently visible (upstream default).
/// - `auto`: bar hides on single-tab workspaces but reveals when the
///   pointer hovers the top edge; multi-tab workspaces always show
///   the bar so tab switching stays click-discoverable.
/// - `never`: bar is never rendered, even with multiple top tabs.
enum WorkspaceTopTabsVisibility: String, CaseIterable, Sendable {
    case always
    case auto
    case never

    /// Visibility passed to the BonsplitController at workspace
    /// construction time. The host view drives the runtime override
    /// for `auto` based on hover state, so this only sets the resting
    /// baseline.
    var bonsplitVisibility: TabBarVisibility {
        switch self {
        case .always:
            return .always
        case .auto:
            // Resting baseline: bar hidden regardless of tab count. The host
            // view flips this to .always while the pointer hovers the top
            // edge so the bar reveals on demand.
            return .never
        case .never:
            return .never
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
