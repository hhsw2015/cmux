import CmuxWorkspaceCore
import CmuxPanes
import Bonsplit
import CmuxSettings
import Combine
import Foundation

// ponytail: P43 merge stubs. Upstream lifted these types into packages
// (CmuxPanes, CmuxRemoteSession, CmuxSettings); fork still calls the legacy
// names in TerminalController + a couple of debug/restore paths. Re-export
// thin shims so the merge builds; replace with proper package calls in P44+.

import CmuxSettings

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




extension Workspace {
    var layoutMode: WorkspaceLayoutMode { get { .splits } set {} }
    var canvasModel: CanvasModel { CanvasModel(metricsProvider: { CanvasMetrics() }) }
}



import Combine
import CmuxCanvas
import CmuxCanvasUI

// ponytail: panelsPublisher / paneLayoutVersionPublisher now stored on Workspace
// (P53 upstream restored them as CurrentValueSubject); stub overrides removed.

func shouldRouteTerminalSelectAllToNaturalTextEngine(_ event: Any?) -> Bool { false }
extension SessionPersistencePolicy {
    static func resolvedMaxScrollbackLinesPerTerminal() -> Int { 1000 }
}


struct SessionCanvasPaneSnapshot: Codable, Sendable {
    var id: UUID = UUID()
    var panelId: UUID?
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var panelIds: [UUID]?
    var selectedPanelId: UUID?
}

extension SessionWorkspaceSnapshot {
    var canvasPanes: [SessionCanvasPaneSnapshot]? { nil }
    var layoutMode: String? { nil }
}
struct TerminalForegroundDirectoryResolver {
    init() {}
    func foregroundDirectory(forTTYName ttyName: String) -> String? { nil }
}

// MARK: - PaneTreeHosting
extension Workspace: PaneTreeHosting {
    @MainActor
    public func panelsWillChange(to newValue: [UUID: any Panel]) {
        objectWillChange.send()
        panelsPublisher.send(newValue)
    }

    @MainActor
    public func paneLayoutVersionWillChange(to newValue: Int) {
        objectWillChange.send()
        paneLayoutVersionPublisher.send(newValue)
    }
}

