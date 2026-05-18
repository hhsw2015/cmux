import CMUXSessionDaemon
import Foundation
import GhosttyKit

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

    func snapshot() -> [ZmxPanelBinder.PanelSnapshot] {
        var snapshots: [ZmxPanelBinder.PanelSnapshot] = []
        var dead: [UUID] = []
        for (panelId, entry) in entries {
            guard let box = entry.box else {
                dead.append(panelId)
                continue
            }
            snapshots.append(ZmxPanelBinder.PanelSnapshot(
                workspaceId: box.workspaceId,
                panelId: panelId,
                surface: box.surface,
                surfaceLive: box.surfaceLive,
                workingDirectory: box.workingDirectory,
                publishSessionName: box.publishSessionName
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
        /// Push session name updates back to the panel (badges, titles…).
        /// Called on the main actor after each binder reconcile.
        var publishSessionName: (String?) -> Void

        init(
            workspaceId: UUID,
            surface: ghostty_surface_t?,
            surfaceLive: Bool,
            workingDirectory: String?,
            publishSessionName: @escaping (String?) -> Void = { _ in }
        ) {
            self.workspaceId = workspaceId
            self.surface = surface
            self.surfaceLive = surfaceLive
            self.workingDirectory = workingDirectory
            self.publishSessionName = publishSessionName
        }
    }
}

/// Synchronous @MainActor mirror of the binding index. Populated by the
/// binder after each successful upsert so cmux's session-save path (which
/// is sync) can ask for "what zmx session is this panel currently in" in
/// O(1) without awaiting an actor hop.
@MainActor
enum ZmxPanelBindingCache {
    private static var bindings: [UUID: SessionZmxBindingSnapshot] = [:]

    static func record(_ snapshot: SessionZmxBindingSnapshot, panelId: UUID) {
        bindings[panelId] = snapshot
    }

    static func clear(panelId: UUID) {
        bindings.removeValue(forKey: panelId)
    }

    static func snapshot(panelId: UUID) -> SessionZmxBindingSnapshot? {
        bindings[panelId]
    }
}

/// Bridges Ghostty's foreground-pid API (`ghostty_surface_foreground_pid`)
/// into the CMUXSessionDaemon binding model so panels can be matched to the live
/// `zmx attach <name>` invocations they host.
///
/// Lives outside the package because it depends on GhosttyKit, which the
/// package can't import without dragging the whole xcframework into Swift PM.
enum ZmxPanelBinder {
    /// Sweep every live terminal panel; for any whose foreground process is a
    /// tracked zmx attach, write/refresh its `RestorableZmxBinding`. Marks
    /// panels whose foreground left zmx (or whose surface is no longer live)
    /// as `.detached` so the next launch doesn't auto-attach a stale binding.
    @MainActor
    static func sweep(panels: [PanelSnapshot]) async {
        for panel in panels {
            await reconcile(panel: panel)
        }
    }

    @MainActor
    static func reconcile(panel: PanelSnapshot) async {
        let existing = await ZmxBindingIndex.shared.lookup(panelId: panel.panelId)

        guard let surface = panel.surface, panel.surfaceLive else {
            // Surface gone: keep the existing binding around but flag it
            // detached so RestorePlanner falls into the offerReattach branch.
            if existing != nil {
                await ZmxBindingIndex.shared.update(panelId: panel.panelId, state: .detached)
            }
            ZmxPanelBindingCache.clear(panelId: panel.panelId)
            panel.publishSessionName(nil)
            return
        }
        let rawPid = ghostty_surface_foreground_pid(surface)
        guard rawPid > 0, rawPid <= UInt64(Int32.max) else {
            if existing != nil {
                await ZmxBindingIndex.shared.update(panelId: panel.panelId, state: .detached)
            }
            ZmxPanelBindingCache.clear(panelId: panel.panelId)
            panel.publishSessionName(nil)
            return
        }
        let foregroundPid = pid_t(rawPid)
        guard let argv = ProcessArgvReader.argv(forPid: foregroundPid),
              let parsed = ZmxArgvParser.parse(argv) else {
            // Foreground process is not a tracked zmx attach. If we previously
            // bound this panel, mark it as detached — the user dropped out of
            // zmx but the daemon may still be alive.
            if existing != nil {
                await ZmxBindingIndex.shared.update(panelId: panel.panelId, state: .detached)
            }
            ZmxPanelBindingCache.clear(panelId: panel.panelId)
            panel.publishSessionName(nil)
            return
        }
        // Preserve the original attachedAt across re-attaches so the model
        // captures "when did this panel first join this session" rather than
        // "when did the binder last sweep".
        let attachedAt = (existing?.zmxSessionName == parsed.sessionName)
            ? (existing?.attachedAt ?? .init())
            : .init()
        let binding = RestorableZmxBinding(
            workspaceId: panel.workspaceId,
            panelId: panel.panelId,
            zmxSessionName: parsed.sessionName,
            zmxBinaryPath: ZmxLocator.resolveBinary()?.path ?? "/usr/local/bin/zmx",
            socketPath: nil,
            originalArgv: argv,
            workingDirectory: panel.workingDirectory ?? FileManager.default.currentDirectoryPath,
            attachState: .attached,
            attachedAt: attachedAt,
            lastSeenAt: .init()
        )
        await ZmxBindingIndex.shared.upsert(binding)
        ZmxPanelBindingCache.record(
            SessionZmxBindingSnapshot(binding: binding),
            panelId: panel.panelId
        )
        panel.publishSessionName(parsed.sessionName)
    }

    /// Plain-data view of what `ZmxPanelBinder` needs from cmux: a panel id,
    /// its workspace id, the Ghostty surface handle, a liveness flag, an
    /// optional cwd, and a `publishSessionName` callback so the binder can
    /// surface state changes back into the panel (badges, titles…).
    struct PanelSnapshot {
        let workspaceId: UUID
        let panelId: UUID
        let surface: ghostty_surface_t?
        let surfaceLive: Bool
        let workingDirectory: String?
        let publishSessionName: (String?) -> Void
    }
}
