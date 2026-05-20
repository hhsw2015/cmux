import CMUXSessionDaemon
import Foundation

/// Errors raised by HerdrBackend.
enum HerdrBackendError: Error, Equatable {
    /// Reserved for unsupported transport variants. SSH stdio is now
    /// supported via `SSHStdioTransport`; this case only fires if a new
    /// `HerdrHost.Transport` enum variant is added without backend
    /// support.
    case remoteNotSupportedYet
}

/// `SessionDaemonBackend` implementation talking to a herdr daemon
/// through the cmux fork's API socket.
///
/// One `HerdrBackend` per host. Lifetime: created lazily by the host
/// registry when first activated, kept around for the run, torn down on
/// host removal or app exit.
///
/// Scope today (B5):
/// - `locateBinary` / `version` / `listSessions` / `isAlive` / `kill`
///   — minimum SessionDaemonBackend surface.
/// - Conformance to the protocol so existing cmux UI plumbing (sidebar,
///   exit banners, agent feed bridges) can light up unchanged once a
///   panel is bound to a herdr-managed pane.
///
/// Out of scope for B5, intentionally:
/// - DeepSessionDaemonBackend (worktree/project) — herdr has no
///   worktree concept; cmux keeps that state in ProjectManifest.
/// - Detach/reattach semantics — handled at the panel layer in B6+ via
///   HerdrDisplayClient lifecycle, not via the protocol's
///   detach/reattach hooks (those are zmx/tsm-shaped).
final class HerdrBackend: SessionDaemonBackend, @unchecked Sendable {
    let kind = SessionDaemonKind.herdr

    let host: HerdrHost
    let executablePath: String
    private let api: HerdrApiClient
    private let transport: any HerdrTransport

    init(host: HerdrHost, executablePath: String) throws {
        self.host = host
        self.executablePath = executablePath
        self.transport = HerdrTransportFactory.make(host: host)
        self.api = HerdrApiClient(transport: self.transport)
    }

    /// Connect the underlying API socket. Idempotent.
    ///
    /// For `.localUDS` hosts: if the API socket file doesn't exist, the
    /// daemon isn't running. Spawn `herdr-cmux --session <name> server`
    /// in the background and poll for the socket up to ~3 s before
    /// attempting the connect. Removes the manual "start herdr first"
    /// step that previously broke first-time UX.
    func start() async throws {
        if case .localUDS = host.transport {
            try await ensureLocalDaemonRunning()
        }
        try await api.start()
    }

    private func ensureLocalDaemonRunning() async throws {
        let socketPath = host.localApiSocketPath
        if FileManager.default.fileExists(atPath: socketPath) {
            return
        }
        // Coalesce concurrent spawns: if another start() is already
        // launching the daemon for this socket, await its result instead
        // of running a second `herdr-cmux server` (which would race for
        // the same UDS path and either fail or leak a zombie process).
        try await DaemonSpawnCoordinator.shared.spawnIfNeeded(
            socketPath: socketPath,
            executablePath: executablePath,
            sessionName: host.sessionName
        )
    }

    func close() async {
        await api.close()
    }

    // MARK: - SessionDaemonBackend

    func locateBinary() -> URL? {
        let url = URL(fileURLWithPath: executablePath)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func version() -> String? {
        // Synchronous; cheap probe of binary metadata.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let text = String(data: data ?? Data(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return nil
        }
        return text
    }

    func listSessions() async throws -> [DaemonSession] {
        // Each herdr workspace is treated as one logical "session" from
        // cmux's protocol-level view. Pane-level granularity is exposed
        // separately by the host's pane registry, not via this method.
        let result: [String: Any]
        do {
            result = try await api.request(method: "workspace.list", params: [:])
        } catch let err as HerdrApiError {
            throw SessionDaemonError.nonZeroExit(status: -1, stderr: err.message)
        }
        guard let workspaces = result["workspaces"] as? [[String: Any]] else {
            return []
        }
        return workspaces.compactMap { ws in
            guard let id = ws["workspace_id"] as? String else { return nil }
            let label = ws["label"] as? String ?? id
            let paneCount = ws["pane_count"] as? Int ?? 0
            let agentStatus = ws["agent_status"] as? String
            return DaemonSession(
                name: id,
                pid: nil,
                cmd: label,
                dir: "",
                state: paneCount > 0 ? .running : .exited,
                clientCount: 0,
                agentKind: agentStatus
            )
        }
    }

    func isAlive(_ name: String) async -> Bool {
        guard let sessions = try? await listSessions() else { return false }
        return sessions.contains { $0.name == name }
    }

    func kill(_ name: String, force: Bool) async throws {
        // herdr has no top-level "kill workspace" beyond `workspace.close`;
        // closing terminates all panes.
        do {
            _ = try await api.request(
                method: "workspace.close",
                params: ["workspace_id": name]
            )
        } catch let err as HerdrApiError {
            throw SessionDaemonError.nonZeroExit(status: -1, stderr: err.message)
        }
    }

    enum CapabilitiesProbe {
        /// Daemon supports the methods cmux needs for the
        /// HerdrPanelOpener workspace path. `version` is the daemon's
        /// reported version string, useful in logs.
        case ok(version: String)
        /// Daemon is reachable but lacks one or more required
        /// methods. `reason` describes which probe failed.
        case incompatible(reason: String)
    }

    /// Verify the daemon supports the methods cmux's workspace
    /// materializer relies on (D1-D4: layout.snapshot, pane.set_split_ratio,
    /// pane.swap, pane.focus, tab.reorder + their Subscription /
    /// EventKind variants). We check by issuing a layout.snapshot call
    /// against a non-existent workspace; the daemon will return either
    /// `tab_not_found` (compatible) or `invalid_request` /
    /// `unknown variant` (incompatible).
    func probeCapabilities() async -> CapabilitiesProbe {
        let version: String
        do {
            let pong = try await api.ping()
            version = pong.version
        } catch {
            return .incompatible(reason: "ping failed: \(error)")
        }
        do {
            _ = try await api.request(
                method: "layout.snapshot",
                params: ["workspace_id": "_cmux_probe_", "tab_id": "_cmux_probe_:1"]
            )
            return .ok(version: version)
        } catch let err as HerdrApiError {
            if err.code == "tab_not_found" || err.code == "workspace_not_found" {
                return .ok(version: version)
            }
            if err.code == "invalid_request" || err.message.contains("unknown variant") {
                return .incompatible(
                    reason:
                        "daemon \(version) lacks layout.snapshot — rebuild herdr-cmux from the cmux fork (master) and restart the daemon"
                )
            }
            return .incompatible(reason: "layout.snapshot probe failed: \(err.code) \(err.message)")
        } catch {
            return .incompatible(reason: "layout.snapshot probe failed: \(error)")
        }
    }

    func parseAttachInvocation(_ argv: [String]) -> ParsedDaemonAttach? {
        // herdr doesn't run the user's process under a shell-attach
        // wrapper the way zmx/tsm do, so there's no argv pattern to
        // parse. Return nil to opt this backend out of the legacy
        // attach-arg detection path.
        return nil
    }
}
