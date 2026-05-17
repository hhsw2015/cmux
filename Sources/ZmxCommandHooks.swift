import AppKit
import CMUXZmx
import Foundation

/// Bridge between cmux's command palette and the CMUXZmx package.
///
/// All blocking work (zmx subprocess calls) runs on detached tasks so the
/// main thread never waits on `Process.waitUntilExit`. Mutating ops funnel
/// through the `ZmxBindingIndex` actor so the JSON store stays serialized.
enum ZmxCommandHooks {
    struct OrphanSession: Hashable {
        let name: String
    }

    /// `zmx ls --short` filtered to entries cmux has no binding for.
    /// Returns [] when zmx is not installed or fails. UI can display this list
    /// behind a "List orphan zmx sessions" command.
    static func listOrphanSessions() async -> [OrphanSession] {
        guard let binary = ZmxLocator.resolveBinary() else { return [] }
        let alive = await Self.runListAlive(binary: binary)
        guard let alive else { return [] }
        let bindings = await ZmxBindingIndex.shared.all()
        let knownNames = Set(bindings.map(\.zmxSessionName))
        let orphans = alive.subtracting(knownNames).sorted()
        return orphans.map(OrphanSession.init(name:))
    }

    /// Kill a zmx session by name and remove any matching bindings. Used by
    /// the "Kill zmx session…" palette command after the user picks a name.
    static func killSession(_ name: String, force: Bool = false) async -> Result<Void, Error> {
        guard let binary = ZmxLocator.resolveBinary() else {
            return .failure(ZmxCommandError.zmxNotInstalled)
        }
        let killResult = await Self.runKill(binary: binary, name: name, force: force)
        switch killResult {
        case .success:
            await ZmxBindingIndex.shared.purge(sessionName: name)
            return .success(())
        case .failure(let error):
            // If the session was already gone (zmx exits non-zero), treat as
            // a successful cleanup so stale bindings get removed.
            if let zmxError = error as? ZmxClientError,
               case .nonZeroExit = zmxError {
                await ZmxBindingIndex.shared.purge(sessionName: name)
            }
            return .failure(error)
        }
    }

    /// One-shot reconcile: call `zmx ls`, mark dead sessions as `.lost`,
    /// return the bindings that flipped state for caller-side notifications.
    static func reconcile() async -> [RestorableZmxBinding] {
        guard let binary = ZmxLocator.resolveBinary() else { return [] }
        let alive = await Self.runListAlive(binary: binary)
        guard let alive else { return [] }
        return await ZmxBindingIndex.shared.reconcile(aliveSessions: alive)
    }

    /// Whether the zmx binary is installed and runnable. Used to gate
    /// command-palette commands and settings UI.
    static func isAvailable() -> Bool {
        guard let binary = ZmxLocator.resolveBinary() else { return false }
        return ZmxLocator.isExecutable(binary)
    }

    // MARK: - Off-main subprocess wrappers

    private static func runListAlive(binary: URL) async -> Set<String>? {
        await Task.detached(priority: .utility) {
            let client = ZmxClient(binaryPath: binary)
            return try? client.listAlive()
        }.value
    }

    private static func runKill(binary: URL, name: String, force: Bool) async -> Result<Void, Error> {
        await Task.detached(priority: .utility) {
            let client = ZmxClient(binaryPath: binary)
            do {
                try client.kill(name, force: force)
                return Result<Void, Error>.success(())
            } catch {
                return Result<Void, Error>.failure(error)
            }
        }.value
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
