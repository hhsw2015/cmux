import CmuxWorkspaceCore
import Bonsplit
import CmuxSettings
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

// ponytail: P45 stubs.
extension Workspace {
    func removeSurfaceMapping(tabId: Any?, panelId: UUID) {}
}

// ponytail: forLayoutTabId stub
extension Workspace {
    func bonsplitController(forLayoutTabId layoutTabId: UUID) -> BonsplitController? {
        bonsplitController
    }
}

extension Workspace {
    var layoutTabId: UUID? { nil }
}

extension Workspace {
    func bonsplitController(containingPaneId pid: Any) -> BonsplitController? {
        bonsplitController
    }
}

extension Workspace {
    func layoutTabId(containingPaneId pid: Any) -> UUID? { nil }
}




extension Workspace {
    var layoutMode: WorkspaceLayoutMode { get { .splits } set {} }
    var canvasModel: CanvasModel { CanvasModel(metricsProvider: { CanvasMetrics() }) }
}



import Combine
import CmuxCanvas
import CmuxCanvasUI

extension Workspace {
    var panelsPublisher: AnyPublisher<[UUID: any Panel], Never> {
        Just([UUID: any Panel]()).eraseToAnyPublisher()
    }
}

extension Workspace {
    var paneLayoutVersionPublisher: AnyPublisher<Int, Never> {
        Just(0).eraseToAnyPublisher()
    }
}

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

enum CloseTabWarningSettings {
    static func hidesTabCloseButton() -> Bool { false }
}

enum CloseTabConfirmationPolicy {
    enum Source { case tabCloseButton, shortcut }
    static func shouldConfirm(requiresConfirmation: Bool = false, source: Source) -> Bool { requiresConfirmation }
}

enum CommandPaletteRenameSelectionSettings {
    static let selectAllOnFocusKey = "commandPalette.renameSelectAllOnFocus"
    static let defaultSelectAllOnFocus = true
    static func selectAllOnFocusEnabled() -> Bool { true }
}

struct TerminalForegroundDirectoryResolver {
    init() {}
    func foregroundDirectory(forTTYName ttyName: String) -> String? { nil }
}
