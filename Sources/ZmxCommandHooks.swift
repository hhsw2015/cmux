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

    /// `zmx ls --short` filtered to entries cmux has neither a panel binding
    /// nor a tracker entry for. Returns [] when zmx is not installed or
    /// `zmx ls` fails. UI can display this list behind a "List orphan zmx
    /// sessions" command.
    static func listOrphanSessions() async -> [OrphanSession] {
        guard let binary = ZmxLocator.resolveBinary() else { return [] }
        let alive = await Self.runListAlive(binary: binary)
        guard let alive else { return [] }
        let bindings = await ZmxBindingIndex.shared.all()
        let known = await ZmxKnownSessionsTracker.shared.all()
        let claimedNames = Set(bindings.map(\.zmxSessionName))
            .union(known.map(\.sessionName))
        let orphans = alive.subtracting(claimedNames).sorted()
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

    /// One-shot reconcile: call `zmx ls`, mark dead bindings as `.lost`,
    /// drop disappeared known sessions. Returns the bindings that flipped
    /// state so callers can surface notifications.
    static func reconcile() async -> [RestorableZmxBinding] {
        guard let binary = ZmxLocator.resolveBinary() else { return [] }
        let alive = await Self.runListAlive(binary: binary)
        guard let alive else { return [] }
        let lostBindings = await ZmxBindingIndex.shared.reconcile(aliveSessions: alive)
        _ = await ZmxKnownSessionsTracker.shared.reconcile(aliveSessions: alive)
        return lostBindings
    }

    /// Sweep proc table for live `zmx attach` invocations and record them in
    /// the session-level tracker so cmux remembers which zmx sessions ever
    /// existed in this user's environment. Run periodically (every 30s) and
    /// at app launch.
    static func sweepLiveSessions() async {
        let live = await Task.detached(priority: .utility) {
            ZmxSystemScanner.scan()
        }.value
        await ZmxKnownSessionsTracker.shared.record(live: live)
    }

    /// Whether the zmx binary is installed and runnable. Used to gate
    /// command-palette commands and settings UI.
    static func isAvailable() -> Bool {
        guard let binary = ZmxLocator.resolveBinary() else { return false }
        return ZmxLocator.isExecutable(binary)
    }

    /// User toggle from settings. Defaults to enabled. When disabled, the
    /// AppDelegate timer skips its sweep entirely so cmux performs zero
    /// zmx subprocess work and writes nothing to disk.
    static var integrationEnabled: Bool {
        // UserDefaults read is cheap; checking each tick avoids the need to
        // wire a notification when the user toggles the setting.
        UserDefaults.standard.object(forKey: ZmxSettings.enabledKey) as? Bool
            ?? ZmxSettings.defaultEnabled
    }

    /// Look up the shell input that reattaches a panel to its previous zmx
    /// session. Result is meant to be fed to the panel's `initialInput`
    /// (typed into the freshly-spawned shell), not its `initialCommand`
    /// (which is the shell binary itself). Returns nil when the planner
    /// says no auto-attach is appropriate; callers should fall through to
    /// the panel's normal restore path or surface a "reattach" affordance.
    static func resumeShellInput(forPanelId panelId: UUID) async -> String? {
        guard let binding = await ZmxBindingIndex.shared.lookup(panelId: panelId) else {
            return nil
        }
        guard let binary = ZmxLocator.resolveBinary() else { return nil }
        // Subprocess failure (timeout, daemon socket missing) is *not* the
        // same signal as "the daemon answered with zero sessions", so don't
        // pass it through to the planner — that would treat every binding
        // as lost. Bail out instead and let the next sweep retry.
        guard let alive = await Self.runListAlive(binary: binary) else {
            return nil
        }
        let env = ZmxRestorePlanner.Environment(
            zmxBinaryAvailable: true,
            zmxBinaryExecutable: ZmxLocator.isExecutable(binary),
            aliveSessions: alive
        )
        let action = ZmxRestorePlanner.plan(binding: binding, environment: env)
        switch action {
        case .attach(let argv, let cwd):
            // cmux PTYs receive a string command; quote argv pieces and add
            // an explicit cd so the session reattaches in the panel's
            // recorded directory.
            let quoted = argv.map(Self.shellQuote).joined(separator: " ")
            let cdGuard = "cd \(Self.shellQuote(cwd)) 2>/dev/null; "
            return cdGuard + quoted
        case .offerReattach, .clearBinding, .noop:
            return nil
        }
    }

    private static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        if s.allSatisfy({ $0.isLetter || $0.isNumber || "_-./:@".contains($0) }) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Off-main subprocess wrappers

    /// Returns nil when zmx ls failed for a reason other than "0 sessions"
    /// (subprocess crash, timeout, daemon socket missing). Returns an empty
    /// Set when zmx ls succeeded but no sessions exist — this is the only
    /// case where reconcile should mark every binding as lost.
    private static func runListAlive(binary: URL) async -> Set<String>? {
        await Task.detached(priority: .utility) {
            let client = ZmxClient(binaryPath: binary)
            do {
                return try client.listAlive()
            } catch {
                return nil
            }
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
