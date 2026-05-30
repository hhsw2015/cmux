import Foundation

/// Render an `AppSessionSnapshot` into a Markdown blueprint suitable for hand
/// editing or git versioning. See `SessionBlueprint` for the schema.
enum SessionBlueprintEncoder {
    /// Build a `SessionBlueprint` projection from the snapshot. Always preceded
    /// by `StableLayoutCoordStamper.stamp(_:)` so every panel carries the
    /// position needed to write `splitPath` back out.
    static func blueprint(from snapshot: AppSessionSnapshot) -> SessionBlueprint {
        let stamped = StableLayoutCoordStamper.stamp(snapshot)
        var workspaces: [SessionBlueprint.Workspace] = []
        for window in stamped.windows {
            for ws in window.tabManager.workspaces {
                workspaces.append(workspace(from: ws))
            }
        }
        return SessionBlueprint(
            version: 1,
            createdAt: Date(timeIntervalSince1970: stamped.createdAt),
            workspaces: workspaces
        )
    }

    /// Serialize a `SessionBlueprint` to its on-disk Markdown form.
    static func render(_ blueprint: SessionBlueprint) -> String {
        var lines: [String] = []
        lines.append("# cmux blueprint v\(blueprint.version)")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        lines.append("created: \(formatter.string(from: blueprint.createdAt))")
        lines.append("")

        for ws in blueprint.workspaces {
            lines.append("## Workspace: \(ws.title)  (cwd: \(ws.cwd))")
            lines.append("")
            for tab in ws.topTabs {
                if let name = tab.name {
                    lines.append("### Top tab: \(name)")
                    lines.append("")
                }
                if tab.entries.isEmpty {
                    lines.append("- _(empty)_")
                } else {
                    for entry in tab.entries {
                        lines.append(renderEntry(entry))
                    }
                }
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - private

    private static func workspace(from ws: SessionWorkspaceSnapshot) -> SessionBlueprint.Workspace {
        let title = ws.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
            ?? ws.processTitle
        let panelsById = Dictionary(uniqueKeysWithValues: ws.panels.map { ($0.id, $0) })

        var topTabs: [SessionBlueprint.TopTab] = []
        if let layoutTabs = ws.layoutTabs, !layoutTabs.isEmpty {
            for tab in layoutTabs {
                let name = tab.title?.nonEmptyOrNil
                topTabs.append(SessionBlueprint.TopTab(
                    name: name,
                    entries: entries(layout: tab.layout, panelsById: panelsById)
                ))
            }
        } else {
            topTabs.append(SessionBlueprint.TopTab(
                name: nil,
                entries: entries(layout: ws.layout, panelsById: panelsById)
            ))
        }

        return SessionBlueprint.Workspace(
            title: title,
            cwd: ws.currentDirectory,
            topTabs: topTabs
        )
    }

    private static func entries(
        layout: SessionWorkspaceLayoutSnapshot,
        panelsById: [UUID: SessionPanelSnapshot]
    ) -> [SessionBlueprint.Entry] {
        var out: [SessionBlueprint.Entry] = []
        walk(layout: layout, splitPath: "", panelsById: panelsById, into: &out)
        return out
    }

    private static func walk(
        layout: SessionWorkspaceLayoutSnapshot,
        splitPath: String,
        panelsById: [UUID: SessionPanelSnapshot],
        into out: inout [SessionBlueprint.Entry]
    ) {
        switch layout {
        case .pane(let pane):
            for panelId in pane.panelIds {
                guard let panel = panelsById[panelId] else { continue }
                let path = splitPath.isEmpty ? "root" : splitPath
                out.append(entry(from: panel, splitPath: path))
            }
        case .split(let split):
            walk(
                layout: split.first,
                splitPath: append(splitPath, "L"),
                panelsById: panelsById,
                into: &out
            )
            walk(
                layout: split.second,
                splitPath: append(splitPath, "R"),
                panelsById: panelsById,
                into: &out
            )
        }
    }

    private static func entry(
        from panel: SessionPanelSnapshot,
        splitPath: String
    ) -> SessionBlueprint.Entry {
        switch panel.type {
        case .terminal:
            let term = panel.terminal
            // Prefer a tracked agent's resume command, then zmx attach name,
            // then tmux start command, then a placeholder shell — the user
            // expects to read the file and see what each pane was running.
            let cmd: String = {
                if let agent = term?.agent?.resumeCommand, !agent.isEmpty { return agent }
                if let zmxName = term?.zmx?.zmxSessionName, !zmxName.isEmpty { return "zmx attach \(zmxName)" }
                if let tmux = term?.tmuxStartCommand, !tmux.isEmpty { return tmux }
                return "$SHELL"
            }()
            return .init(
                splitPath: splitPath,
                kind: "terminal",
                command: cmd,
                cwd: term?.workingDirectory
            )
        case .browser:
            return .init(
                splitPath: splitPath,
                kind: "browser",
                command: panel.browser?.urlString ?? "about:blank",
                cwd: nil
            )
        case .markdown:
            return .init(
                splitPath: splitPath,
                kind: "markdown",
                command: panel.markdown?.filePath ?? "",
                cwd: nil
            )
        case .filePreview:
            return .init(
                splitPath: splitPath,
                kind: "filepreview",
                command: panel.filePreview?.filePath ?? "",
                cwd: nil
            )
        case .rightSidebarTool:
            return .init(
                splitPath: splitPath,
                kind: "rightSidebarTool",
                command: panel.rightSidebarTool?.mode?.rawValue ?? "",
                cwd: nil
            )
        case .project:
            return .init(
                splitPath: splitPath,
                kind: "project",
                command: "",
                cwd: nil
            )
        }
    }

    private static func renderEntry(_ entry: SessionBlueprint.Entry) -> String {
        let cwdSuffix = entry.cwd.flatMap { $0.isEmpty ? nil : "  (cwd: \($0))" } ?? ""
        return "- \(entry.splitPath): \(entry.kind) `\(entry.command)`\(cwdSuffix)"
    }

    private static func append(_ path: String, _ token: String) -> String {
        path.isEmpty ? token : "\(path)/\(token)"
    }
}

private extension String {
    var nonEmptyOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Optional where Wrapped == String {
    var nonEmptyOrNil: String? {
        switch self {
        case .none: return nil
        case .some(let s): return s.nonEmptyOrNil
        }
    }
}
