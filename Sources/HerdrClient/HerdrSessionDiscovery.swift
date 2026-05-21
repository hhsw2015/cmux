import Foundation

/// Lists local herdr sessions (`herdr-cmux session list --json`) so
/// cmux can populate the command palette and Settings UI without
/// requiring the user to type session names by hand.
///
/// Sessions live as subdirectories of `~/.config/herdr/sessions/`,
/// each with its own UDS socket. Discovery shells out to the bundled
/// herdr-cmux binary because it's authoritative about the on-disk
/// session layout (and the user can override the prefix). Cached on
/// the main actor; refreshed on demand.
@MainActor
final class HerdrSessionDiscovery: ObservableObject {
    static let shared = HerdrSessionDiscovery()

    /// Snapshot of the latest discovery run.
    struct Session: Equatable, Identifiable, Sendable {
        let name: String
        let directory: String
        let socket: String
        let isRunning: Bool
        var id: String { socket }
    }

    @Published private(set) var sessions: [Session] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var lastError: String?

    private var inflight: Task<Void, Never>?

    private init() {}

    /// Kick off a discovery run. Coalesces with the in-flight task —
    /// repeated calls during one cycle reuse the same Process.
    func refresh() {
        if inflight != nil { return }
        inflight = Task { [weak self] in
            defer { self?.inflight = nil }
            await self?.runOnce()
        }
    }

    private func runOnce() async {
        guard let exec = HerdrLocalBinary.resolve() else {
            self.lastError = String(
                localized: "herdr.session.discovery.no_binary",
                defaultValue: "herdr-cmux binary not found"
            )
            return
        }
        // Spawn + wait happens on a detached task so the main
        // actor isn't pinned for the duration of the subprocess
        // (typically <100 ms but can spike if the herdr config dir
        // is on slow storage). The result is a Sendable value type.
        let result = await Task.detached(priority: .utility) {
            HerdrSessionDiscovery.spawnAndParse(executablePath: exec)
        }.value

        switch result {
        case .success(let parsed):
            self.sessions = parsed
            self.lastRefresh = Date()
            self.lastError = nil
        case .failure(let message):
            self.lastError = message
        }
    }

    private enum DiscoveryResult: Sendable {
        case success([Session])
        case failure(String)
    }

    private static func spawnAndParse(executablePath: String) -> DiscoveryResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = ["session", "list", "--json"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            return .failure("spawn failed: \(error.localizedDescription)")
        }
        let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            return .failure("exit \(proc.terminationStatus)")
        }
        guard let payload = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any],
              let raw = payload["sessions"] as? [[String: Any]] else {
            return .failure("unparseable output")
        }
        let parsed: [Session] = raw.compactMap { item in
            guard let name = item["name"] as? String,
                  let directory = item["directory"] as? String,
                  let socket = item["socket"] as? String
            else { return nil }
            let status = (item["status"] as? String) ?? "unknown"
            return Session(
                name: name,
                directory: directory,
                socket: socket,
                isRunning: status.lowercased() == "running"
            )
        }
        return .success(parsed)
    }

    /// Resolve a discovered Session to a HerdrHost, registering it if
    /// the host isn't already in HostRegistry. Returns nil if no
    /// matching host could be created (shouldn't happen for local
    /// sessions). Idempotent: repeated calls for the same session
    /// return the existing Host.
    func ensureHost(for session: Session) -> HerdrHost? {
        let registry = HostRegistry.shared
        if let existing = registry.hosts.first(where: {
            if case .localUDS = $0.transport, $0.sessionName == session.name {
                return true
            }
            return false
        }) {
            return existing
        }
        let host = HerdrHost(
            id: UUID(),
            displayName: session.name,
            transport: .localUDS,
            sessionName: session.name,
            addedAt: Date()
        )
        guard registry.add(host) else {
            return nil
        }
        return host
    }
}
