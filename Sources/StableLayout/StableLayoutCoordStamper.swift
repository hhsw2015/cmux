import Foundation

/// Walks an `AppSessionSnapshot`'s layout trees and stamps each panel with the
/// `StableLayoutCoord` derived from its position. Run on the writer side just before
/// the snapshot is encoded; run on the reader side as a fallback when UUID matches
/// fail.
///
/// The stamper is value-typed and side-effect free: it returns a new
/// `AppSessionSnapshot` with `stableCoord` populated on every panel. The original
/// snapshot is untouched.
enum StableLayoutCoordStamper {
    /// Decorate every panel in `snapshot` with its computed stable coordinate. Panels
    /// referenced from a pane's `panelIds` whose UUID does not appear in
    /// `workspace.panels` are silently skipped — they will get coords on the next
    /// stamp pass once the panels list catches up.
    static func stamp(_ snapshot: AppSessionSnapshot) -> AppSessionSnapshot {
        var out = snapshot
        for w in out.windows.indices {
            for ws in out.windows[w].tabManager.workspaces.indices {
                out.windows[w].tabManager.workspaces[ws] = stamp(
                    workspace: out.windows[w].tabManager.workspaces[ws]
                )
            }
        }
        return out
    }

    private static func stamp(workspace: SessionWorkspaceSnapshot) -> SessionWorkspaceSnapshot {
        var out = workspace
        let workspaceTitle = effectiveTitle(custom: workspace.customTitle, fallback: workspace.processTitle)
        var coordsById: [UUID: StableLayoutCoord] = [:]
        // ponytail: fork lacks workspace.layoutTabs, only single layout
        walk(layout: workspace.layout, splitPath: "", workspaceTitle: workspaceTitle, topTabTitle: nil, into: &coordsById)

        out.panels = workspace.panels.map { panel in
            var p = panel
            p.stableCoord = coordsById[panel.id]
            return p
        }
        return out
    }

    private static func effectiveTitle(custom: String?, fallback: String) -> String {
        if let t = custom?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        return fallback
    }

    private static func walk(
        layout: SessionWorkspaceLayoutSnapshot,
        splitPath: String,
        workspaceTitle: String,
        topTabTitle: String?,
        into out: inout [UUID: StableLayoutCoord]
    ) {
        switch layout {
        case .pane(let pane):
            for (panelIdx, panelId) in pane.panelIds.enumerated() {
                out[panelId] = StableLayoutCoord(
                    workspaceTitle: workspaceTitle,
                    topTabTitle: topTabTitle,
                    splitPath: splitPath,
                    paneIndex: 0,
                    panelIndexInPane: panelIdx
                )
            }
        case .split(let split):
            walk(
                layout: split.first,
                splitPath: append(splitPath, "L"),
                workspaceTitle: workspaceTitle,
                topTabTitle: topTabTitle,
                into: &out
            )
            walk(
                layout: split.second,
                splitPath: append(splitPath, "R"),
                workspaceTitle: workspaceTitle,
                topTabTitle: topTabTitle,
                into: &out
            )
        }
    }

    private static func append(_ path: String, _ token: String) -> String {
        path.isEmpty ? token : "\(path)/\(token)"
    }
}
