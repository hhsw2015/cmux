import Foundation

extension AppDelegate {
    func paneMemoryGuardrailDescriptors() -> [PaneMemoryDescriptor] {
        paneMemoryGuardrailTabManagers().flatMap { manager in
            manager.tabs.flatMap { workspace in
                paneMemoryGuardrailDescriptors(in: workspace)
            }
        }
    }

    func discardHiddenBrowserWebViewsForSystemMemoryPressure() {
        let now = Date()
        let discardedCount = paneMemoryGuardrailTabManagers().reduce(0) { count, manager in
            count + manager.discardHiddenBrowserWebViewsForSystemMemoryPressure(now: now)
        }
#if DEBUG
        cmuxDebugLog("browser.memoryPressure.discardHidden count=\(discardedCount)")
#endif
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
}
