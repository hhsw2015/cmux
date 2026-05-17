import AppKit
import CMUXZmx
import Foundation

/// Bridge between cmux's command palette and the CMUXZmx package.
///
/// Kept as a thin static API so ContentView can register zmx commands without
/// adopting any cmx-internal dependency on Process or Foundation processes.
/// All side effects funnel through `ZmxClient` / `ZmxBindingIndex` so they
/// remain testable in the package.
enum ZmxCommandHooks {
    struct OrphanSession: Hashable {
        let name: String
    }

    /// `zmx ls --short` filtered to entries cmux has no binding for.
    /// Returns [] when zmx is not installed or fails. UI can display this list
    /// behind a "List orphan zmx sessions" command.
    @MainActor
    static func listOrphanSessions() async -> [OrphanSession] {
        guard let binary = ZmxLocator.resolveBinary() else { return [] }
        let client = ZmxClient(binaryPath: binary)
        guard let alive = try? client.listAlive() else { return [] }
        let bindings = await ZmxBindingIndex.shared.all()
        let knownNames = Set(bindings.map(\.zmxSessionName))
        let orphans = alive.subtracting(knownNames).sorted()
        return orphans.map(OrphanSession.init(name:))
    }

    /// Kill a zmx session by name and remove any matching bindings. Used by
    /// the "Kill zmx session…" palette command after the user picks a name.
    @MainActor
    static func killSession(_ name: String, force: Bool = false) async -> Result<Void, Error> {
        guard let binary = ZmxLocator.resolveBinary() else {
            return .failure(ZmxCommandError.zmxNotInstalled)
        }
        let client = ZmxClient(binaryPath: binary)
        do {
            try client.kill(name, force: force)
        } catch {
            return .failure(error)
        }
        let bindings = await ZmxBindingIndex.shared.all()
        for b in bindings where b.zmxSessionName == name {
            await ZmxBindingIndex.shared.remove(panelId: b.panelId)
        }
        return .success(())
    }

    /// One-shot reconcile: call `zmx ls`, mark dead sessions as `.lost`,
    /// return the bindings that flipped state for caller-side notifications.
    @MainActor
    static func reconcile() async -> [RestorableZmxBinding] {
        guard let binary = ZmxLocator.resolveBinary() else { return [] }
        let client = ZmxClient(binaryPath: binary)
        guard let alive = try? client.listAlive() else { return [] }
        return await ZmxBindingIndex.shared.reconcile(aliveSessions: alive)
    }

    /// Whether the zmx binary is installed and runnable. Used to gate
    /// command-palette commands and settings UI.
    static func isAvailable() -> Bool {
        guard let binary = ZmxLocator.resolveBinary() else { return false }
        return ZmxLocator.isExecutable(binary)
    }
}

enum ZmxCommandError: Error, LocalizedError {
    case zmxNotInstalled

    var errorDescription: String? {
        switch self {
        case .zmxNotInstalled:
            return String(
                localized: "zmx.error.notInstalled",
                defaultValue: "zmx is not installed. Install with `brew install zmx` or visit github.com/neurosnap/zmx."
            )
        }
    }
}
