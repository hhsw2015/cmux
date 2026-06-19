import Foundation

extension AppDelegate {
    func paneMemoryGuardrailDescriptors() -> [PaneMemoryDescriptor] {
        paneMemoryGuardrailTabManagers().flatMap { manager in
            manager.tabs.flatMap { workspace in
                paneMemoryGuardrailDescriptors(in: workspace)
            }
        }
    }

    private func paneMemoryGuardrailTabManagers() -> [TabManager] {
        var managers: [TabManager] = []
        var seen: Set<ObjectIdentifier> = []

        func append(_ manager: TabManager?) {
            guard let manager else { return }
            let id = ObjectIdentifier(manager)
            guard seen.insert(id).inserted else { return }
            managers.append(manager)
        }

        for context in mainWindowContexts.values {
            append(context.tabManager)
        }
        for route in recoverableMainWindowRoutes() {
            append(route.tabManager)
        }
        append(tabManager)
        return managers
    }

    private func paneMemoryGuardrailDescriptors(in workspace: Workspace) -> [PaneMemoryDescriptor] {
        // ponytail: fork TerminalSurface lacks controllingTTYName/foregroundProcessID;
        // pane-memory guardrail telemetry is a no-op on this branch.
        return []
    }

    @discardableResult
    func closePaneForMemoryGuardrail(workspaceId: UUID, panelId: UUID) -> Bool {
        guard let manager = tabManagerFor(tabId: workspaceId) ?? tabManager else { return false }
        return manager.closeSurface(tabId: workspaceId, surfaceId: panelId)
    }
}
