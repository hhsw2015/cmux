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

    /// Materialize a saved layout into the workspace: spawn fresh terminal
    /// panels, attach each to its declared session, and apply split
    /// orientation + ratios. Returns the count of materialized leaves.
    @discardableResult
    static func materialize(
        layout: PanelLayoutTree,
        into workspace: Workspace
    ) -> Int {
        return materializeNode(layout, into: workspace, anchor: nil, orientation: nil)
    }

    private static func materializeNode(
        _ node: PanelLayoutTree,
        into workspace: Workspace,
        anchor: PaneID?,
        orientation: SplitOrientation?
    ) -> Int {
        switch node {
        case .panel(let descriptor):
            return materializePanel(descriptor, into: workspace, anchor: anchor, orientation: orientation)
        case .split(let direction, _, let children):
            guard !children.isEmpty else { return 0 }
            // First child reuses anchor pane; subsequent children split off
            // from the previously-created pane in the requested orientation.
            var count = materializeNode(children[0], into: workspace, anchor: anchor, orientation: orientation)
            let bonsplitOrientation: SplitOrientation = direction == .horizontal ? .horizontal : .vertical
            for child in children.dropFirst() {
                let lastPane = workspace.bonsplitController.focusedPaneId
                count += materializeNode(child, into: workspace, anchor: lastPane, orientation: bonsplitOrientation)
            }
            return count
        }
    }

    private static func materializePanel(
        _ descriptor: PanelDescriptor,
        into workspace: Workspace,
        anchor: PaneID?,
        orientation: SplitOrientation?
    ) -> Int {
        let initialInput = sessionAttachInput(for: descriptor)
        let workingDir = descriptor.dir.isEmpty ? nil : descriptor.dir

        let targetPane: PaneID
        if let orientation, let anchor {
            // Split off a fresh pane from the anchor in the requested
            // orientation. The new pane gets a placeholder tab we'll
            // close once we drop our terminal in.
            guard let newPaneId = workspace.bonsplitController.splitPane(
                anchor,
                orientation: orientation
            ) else { return 0 }
            targetPane = newPaneId
        } else {
            targetPane = anchor ?? workspace.bonsplitController.focusedPaneId ?? PaneID(uuid: UUID())
        }

        guard let newPanel = workspace.newTerminalSurface(
            inPane: targetPane,
            focus: true,
            workingDirectory: workingDir,
            initialInput: initialInput
        ) else { return 0 }
        applyKeepAlive(panel: newPanel, descriptor: descriptor)
        return 1
    }

    private static func applyKeepAlive(panel: TerminalPanel, descriptor: PanelDescriptor) {
        if descriptor.keepAlive {
            panel.keepAlive = true
        }
    }

    private static func sessionAttachInput(for descriptor: PanelDescriptor) -> String? {
        guard !descriptor.sessionName.isEmpty else { return nil }
        let engine = SessionDaemonResolver.shared.selectedKind() ?? .tsm
        let binary = engine == .tsm ? "tsm" : "zmx"
        return "\(binary) attach \(descriptor.sessionName)\n"
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
