import CMUXSessionDaemon
import Foundation

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

    init(host: HerdrHost, executablePath: String) {
        self.host = host
        self.executablePath = executablePath
        switch host.transport {
        case .localUDS:
            let socketPath = (("~/.config/herdr/sessions/" + host.sessionName + "/herdr.sock") as NSString)
                .expandingTildeInPath
            self.transport = LocalUDSTransport(socketPath: socketPath)
        case .sshStdio:
            // SSH stdio transport for the API socket lands in B7. Until
            // then a placeholder LocalUDSTransport is created that will
            // simply fail to connect when start() is called.
            self.transport = LocalUDSTransport(socketPath: "/dev/null/cmux-herdr-ssh-not-yet")
        }
        self.api = HerdrApiClient(transport: self.transport)
    }

    /// Connect the underlying API socket. Idempotent.
    func start() async throws {
        try await api.start()
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

    func parseAttachInvocation(_ argv: [String]) -> ParsedDaemonAttach? {
        // herdr doesn't run the user's process under a shell-attach
        // wrapper the way zmx/tsm do, so there's no argv pattern to
        // parse. Return nil to opt this backend out of the legacy
        // attach-arg detection path.
        return nil
    }
}
