import CMUXZmx
import Foundation
import GhosttyKit

/// Bridges Ghostty's foreground-pid API (`ghostty_surface_foreground_pid`)
/// into the CMUXZmx binding model so panels can be matched to the live
/// `zmx attach <name>` invocations they host.
///
/// Lives outside the package because it depends on GhosttyKit, which the
/// package can't import without dragging the whole xcframework into Swift PM.
extension Notification.Name {
    /// Posted by the AppDelegate timer; the panel registry's observer runs
    /// the binder sweep against every registered terminal panel.
    static let zmxPanelBinderSweepRequested = Notification.Name("com.cmuxterm.zmx.binderSweep")
}

/// Weak registry of every live terminal panel + its Ghostty surface. Populated
/// by `TerminalPanel` on init and cleared on deinit. The binder iterates this
/// list during periodic sweeps so it doesn't need to walk SwiftUI hierarchies.
@MainActor
final class ZmxPanelRegistry {
    static let shared = ZmxPanelRegistry()

    private struct Entry {
        weak var box: PanelBox?
    }

    private var entries: [UUID: Entry] = [:]

    func register(workspaceId: UUID, panelId: UUID, box: PanelBox) {
        entries[panelId] = Entry(box: box)
    }

    func unregister(panelId: UUID) {
        entries.removeValue(forKey: panelId)
    }

    nonisolated func scheduleUnregister(panelId: UUID) {
        Task { @MainActor [self] in
            unregister(panelId: panelId)
        }
    }

    func snapshot(refresh: (UUID, PanelBox) -> Void = { _, _ in }) -> [ZmxPanelBinder.PanelSnapshot] {
        var snapshots: [ZmxPanelBinder.PanelSnapshot] = []
        var dead: [UUID] = []
        for (panelId, entry) in entries {
            guard let box = entry.box else {
                dead.append(panelId)
                continue
            }
            refresh(panelId, box)
            snapshots.append(ZmxPanelBinder.PanelSnapshot(
                workspaceId: box.workspaceId,
                panelId: panelId,
                surface: box.surface,
                surfaceLive: box.surfaceLive,
                workingDirectory: box.workingDirectory
            ))
        }
        for id in dead {
            entries.removeValue(forKey: id)
        }
        return snapshots
    }

    /// Adapter object bridging cmux's TerminalPanel to the binder without
    /// dragging Ghostty types through @MainActor constraints in tests.
    final class PanelBox {
        var workspaceId: UUID
        var surface: ghostty_surface_t?
        var surfaceLive: Bool
        var workingDirectory: String?

        init(workspaceId: UUID, surface: ghostty_surface_t?, surfaceLive: Bool, workingDirectory: String?) {
            self.workspaceId = workspaceId
            self.surface = surface
            self.surfaceLive = surfaceLive
            self.workingDirectory = workingDirectory
        }
    }
}

enum ZmxPanelBinder {
    /// Sweep every live terminal panel; for any whose foreground process is a
    /// tracked zmx attach, write/refresh its `RestorableZmxBinding`. Drop
    /// stale bindings when a panel no longer hosts a zmx process.
    @MainActor
    static func sweep(panels: [PanelSnapshot]) async {
        for panel in panels {
            await reconcile(panel: panel)
        }
    }

    @MainActor
    static func reconcile(panel: PanelSnapshot) async {
        guard let surface = panel.surface, panel.surfaceLive else {
            return
        }
        let foregroundPid = pid_t(ghostty_surface_foreground_pid(surface))
        guard foregroundPid > 0 else {
            await ZmxBindingIndex.shared.update(panelId: panel.panelId, state: .detached)
            return
        }
        guard let argv = ProcessArgvReader.argv(forPid: foregroundPid),
              let parsed = ZmxArgvParser.parse(argv) else {
            // Foreground process is not a tracked zmx attach. If we previously
            // bound this panel, mark it as detached — the user dropped out of
            // zmx but the daemon may still be alive.
            await ZmxBindingIndex.shared.update(panelId: panel.panelId, state: .detached)
            return
        }
        let binding = RestorableZmxBinding(
            workspaceId: panel.workspaceId,
            panelId: panel.panelId,
            zmxSessionName: parsed.sessionName,
            zmxBinaryPath: ZmxLocator.resolveBinary()?.path ?? "/usr/local/bin/zmx",
            socketPath: nil,
            originalArgv: argv,
            workingDirectory: panel.workingDirectory ?? FileManager.default.currentDirectoryPath,
            attachState: .attached,
            attachedAt: .init(),
            lastSeenAt: .init()
        )
        await ZmxBindingIndex.shared.upsert(binding)
    }

    /// Plain-data view of what `ZmxPanelBinder` needs from cmux: a panel id,
    /// its workspace id, the Ghostty surface handle, a liveness flag, and an
    /// optional cwd. Decoupled from `TerminalPanel` so the binder is testable
    /// without Ghostty in scope.
    struct PanelSnapshot {
        let workspaceId: UUID
        let panelId: UUID
        let surface: ghostty_surface_t?
        let surfaceLive: Bool
        let workingDirectory: String?
    }
}
