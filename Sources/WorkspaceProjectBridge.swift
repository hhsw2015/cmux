import Bonsplit
import CMUXZmx
import Foundation

/// Bridges cmux's `Workspace` data model to `ProjectManifest`. Phase 5
/// wiring keeps the conversion intentionally simple: panels are flattened
/// (no split tree captured) so save/open works for the common 1-pane case.
/// Full bonsplit-aware serialization is a follow-up that needs to walk
/// pane geometry — leaving as a TODO so this wiring ships without
/// touching bonsplit internals.
@MainActor
enum WorkspaceProjectBridge {
    static let store = ProjectManifestStore()

    @discardableResult
    static func save(workspace: Workspace, name: String) throws -> ProjectManifest {
        let tree = workspace.bonsplitController.treeSnapshot()
        let layout = layoutTree(from: tree, workspace: workspace)
        let firstDir = layout?.leaves.first?.dir
        let manifest = ProjectManifest(
            name: name,
            rootDirectory: firstDir,
            layouts: layout.map { [ProjectManifest.defaultBranchKey: $0] } ?? [:]
        )
        try store.save(manifest)
        return manifest
    }

    /// Translate bonsplit's external tree into our serialization format.
    /// Each `ExternalPaneNode` becomes a single panel — only the selected
    /// tab is captured; non-selected tabs in a pane are dropped because
    /// our layout schema is one panel per slot.
    private static func layoutTree(
        from node: ExternalTreeNode,
        workspace: Workspace
    ) -> PanelLayoutTree? {
        switch node {
        case .pane(let pane):
            guard let tabId = pane.selectedTabId,
                  let panelId = UUID(uuidString: tabId),
                  let descriptor = descriptor(forPanelId: panelId, workspace: workspace) else {
                return nil
            }
            return .panel(descriptor)
        case .split(let split):
            let firstChild = layoutTree(from: split.first, workspace: workspace)
            let secondChild = layoutTree(from: split.second, workspace: workspace)
            switch (firstChild, secondChild) {
            case (let a?, let b?):
                let direction: PanelLayoutTree.SplitDirection =
                    split.orientation == "vertical" ? .vertical : .horizontal
                return .split(direction: direction, ratio: split.dividerPosition,
                              children: [a, b])
            case (let only?, nil), (nil, let only?):
                return only
            case (nil, nil):
                return nil
            }
        }
    }

    private static func descriptor(
        forPanelId panelId: UUID,
        workspace: Workspace
    ) -> PanelDescriptor? {
        guard let panel = workspace.panels[panelId] as? TerminalPanel else { return nil }
        let session = panel.zmxSessionName ?? ""
        let dir = panel.surface.requestedWorkingDirectory ?? ""
        return PanelDescriptor(
            sessionName: session,
            cmd: "",
            dir: dir,
            capturedCwd: panel.directory.isEmpty ? nil : panel.directory,
            capturedEnv: nil,
            keepAlive: panel.keepAlive
        )
    }

    static func availableProjectNames() -> [String] {
        (try? store.list()) ?? []
    }

    /// Snapshot of the current workspace layout for callers that need it
    /// outside the save path (e.g., BranchWorkspaceSwitcher).
    static func currentLayout(workspace: Workspace) -> PanelLayoutTree? {
        let tree = workspace.bonsplitController.treeSnapshot()
        return layoutTree(from: tree, workspace: workspace)
    }

    /// Returns the manifest's layout for use by Wiring 6 (branch switch)
    /// and by future open-project handlers. Layout materialization itself
    /// happens in cmux's panel-creation path; this bridge only fetches.
    static func loadLayout(name: String, branch: String = ProjectManifest.defaultBranchKey)
        -> PanelLayoutTree? {
        guard let manifest = try? store.load(name: name) else { return nil }
        return manifest.layouts[branch]
    }

}
