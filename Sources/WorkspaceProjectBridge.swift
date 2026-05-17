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
        let descriptors = collectDescriptors(workspace: workspace)
        let layout: PanelLayoutTree?
        if descriptors.isEmpty {
            layout = nil
        } else if descriptors.count == 1 {
            layout = .panel(descriptors[0])
        } else {
            // Flat horizontal split chain — preserves the panel set even
            // if geometry is approximate. A future iteration will walk
            // bonsplit's tree for an exact ratio reproduction.
            layout = chainHorizontally(descriptors)
        }
        let manifest = ProjectManifest(
            name: name,
            rootDirectory: descriptors.first?.dir,
            layouts: layout.map { [ProjectManifest.defaultBranchKey: $0] } ?? [:]
        )
        try store.save(manifest)
        return manifest
    }

    static func availableProjectNames() -> [String] {
        (try? store.list()) ?? []
    }

    /// Returns the manifest's layout for use by Wiring 6 (branch switch)
    /// and by future open-project handlers. Layout materialization itself
    /// happens in cmux's panel-creation path; this bridge only fetches.
    static func loadLayout(name: String, branch: String = ProjectManifest.defaultBranchKey)
        -> PanelLayoutTree? {
        guard let manifest = try? store.load(name: name) else { return nil }
        return manifest.layouts[branch]
    }

    private static func collectDescriptors(workspace: Workspace) -> [PanelDescriptor] {
        workspace.panels.values.compactMap { panel -> PanelDescriptor? in
            guard let terminal = panel as? TerminalPanel else { return nil }
            let session = terminal.zmxSessionName ?? ""
            let dir = terminal.surface.requestedWorkingDirectory ?? ""
            return PanelDescriptor(
                sessionName: session,
                cmd: "",
                dir: dir,
                capturedCwd: terminal.directory.isEmpty ? nil : terminal.directory,
                capturedEnv: nil,
                keepAlive: terminal.keepAlive
            )
        }
    }

    private static func chainHorizontally(_ descriptors: [PanelDescriptor])
        -> PanelLayoutTree {
        guard descriptors.count > 1 else {
            return .panel(descriptors[0])
        }
        return .split(
            direction: .horizontal,
            ratio: 1.0 / Double(descriptors.count),
            children: descriptors.map(PanelLayoutTree.panel)
        )
    }
}
