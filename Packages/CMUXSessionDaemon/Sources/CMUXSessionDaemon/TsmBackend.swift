import Foundation

/// `DeepSessionDaemonBackend` implementation backed by the `tsm` CLI.
///
/// Bundle ID isolation: every cmux instance prefixes its session names with
/// the bundle identifier so a production app and a staging app running side
/// by side don't fight over the same session.
public struct TsmBackend: DeepSessionDaemonBackend {
    public let kind = SessionDaemonKind.tsm
    private let processTimeout: TimeInterval

    public init(processTimeout: TimeInterval = 5.0) {
        self.processTimeout = processTimeout
    }

    public func locateBinary() -> URL? {
        TsmLocator.resolveBinary()
    }

    public func version() -> String? {
        guard let url = locateBinary() else { return nil }
        return TsmLocator.version(at: url)
    }

    public func parseAttachInvocation(_ argv: [String]) -> ParsedDaemonAttach? {
        guard let parsed = TsmArgvParser.parse(argv) else { return nil }
        return ParsedDaemonAttach(sessionName: parsed.sessionName)
    }

    // MARK: - basic surface

    public func listSessions() async throws -> [DaemonSession] {
        let binary = try requireBinary()
        let client = TsmClient(binaryPath: binary, processTimeout: processTimeout)
        return try await Task.detached(priority: .utility) {
            do {
                let names = try client.listSessionNames()
                return names.map { name in
                    DaemonSession(
                        name: name,
                        pid: nil,
                        cmd: "",
                        dir: "",
                        state: .running,
                        clientCount: 0,
                        agentKind: nil
                    )
                }
            } catch let error as TsmClientError {
                throw Self.wrap(error)
            }
        }.value
    }

    public func isAlive(_ name: String) async -> Bool {
        guard let binary = locateBinary() else { return false }
        let client = TsmClient(binaryPath: binary, processTimeout: processTimeout)
        return await Task.detached(priority: .utility) {
            client.isAlive(name)
        }.value
    }

    public func kill(_ name: String, force: Bool) async throws {
        let binary = try requireBinary()
        let client = TsmClient(binaryPath: binary, processTimeout: processTimeout)
        try await Task.detached(priority: .utility) {
            do {
                try client.kill([name], force: force)
            } catch let error as TsmClientError {
                throw Self.wrap(error)
            }
        }.value
    }

    // MARK: - deep surface

    public func createSession(name: String, cmd: String, dir: String) async throws {
        let binary = try requireBinary()
        let client = TsmClient(binaryPath: binary, processTimeout: processTimeout)
        let argv = Self.tokenizeShell(cmd)
        try await Task.detached(priority: .utility) {
            do {
                try client.createSession(name: name, cmd: argv, dir: dir)
            } catch let error as TsmClientError {
                throw Self.wrap(error)
            }
        }.value
    }

    public func detachSession(_ name: String) async throws {
        let binary = try requireBinary()
        let client = TsmClient(binaryPath: binary, processTimeout: processTimeout)
        try await Task.detached(priority: .utility) {
            do {
                try client.detachSession(name)
            } catch let error as TsmClientError {
                throw Self.wrap(error)
            }
        }.value
    }

    public func listWorktrees() async throws -> [DaemonWorktree] {
        let binary = try requireBinary()
        let client = TsmClient(binaryPath: binary, processTimeout: processTimeout)
        return try await Task.detached(priority: .utility) {
            do {
                let raw = try client.worktreeList()
                return Self.parseWorktreeList(raw)
            } catch let error as TsmClientError {
                throw Self.wrap(error)
            }
        }.value
    }

    public func createWorktree(branch: String, base: String?) async throws {
        let binary = try requireBinary()
        let client = TsmClient(binaryPath: binary, processTimeout: processTimeout)
        try await Task.detached(priority: .utility) {
            do {
                try client.worktreeAdd(branch: branch)
            } catch let error as TsmClientError {
                throw Self.wrap(error)
            }
        }.value
    }

    public func switchWorktree(branch: String) async throws {
        let binary = try requireBinary()
        let client = TsmClient(binaryPath: binary, processTimeout: processTimeout)
        try await Task.detached(priority: .utility) {
            do {
                try client.worktreeSwitch(branch: branch)
            } catch let error as TsmClientError {
                throw Self.wrap(error)
            }
        }.value
    }

    public func deleteWorktree(branch: String) async throws {
        let binary = try requireBinary()
        let client = TsmClient(binaryPath: binary, processTimeout: processTimeout)
        try await Task.detached(priority: .utility) {
            do {
                try client.worktreeRemove(branch: branch, force: true)
            } catch let error as TsmClientError {
                throw Self.wrap(error)
            }
        }.value
    }

    public func eventStream() -> AsyncStream<DaemonEvent>? {
        // Phase 5 will implement this on top of FSEvents over the tsm
        // session directory. Returning nil here makes Phase 1 callers
        // fall back to polling, which is correct.
        nil
    }

    // MARK: - bundle id session naming

    /// Suffix used to isolate cmux instances. Production app, staging app,
    /// debug builds get distinct prefixes. Static so callers can reach it
    /// without owning a backend instance.
    public static func bundleSuffix(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override = environment["CMUX_INSTANCE_TAG"], !override.isEmpty {
            return override
        }
        let id = bundle.bundleIdentifier ?? "cmux"
        return id.split(separator: ".").last.map(String.init) ?? "cmux"
    }

    /// Produces "cmux-<bundleSuffix>-<panelIdShort>" so external observers
    /// (and the user) can tell which cmux owns a session.
    public static func sessionName(forPanelId panelId: UUID, bundle: Bundle = .main) -> String {
        let suffix = bundleSuffix(bundle: bundle)
        let short = panelId.uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        return "cmux-\(suffix)-\(short)"
    }

    // MARK: - helpers

    private func requireBinary() throws -> URL {
        guard let binary = locateBinary() else {
            throw SessionDaemonError.binaryNotFound
        }
        return binary
    }

    private static func wrap(_ error: TsmClientError) -> SessionDaemonError {
        switch error {
        case .timeout(let arguments):
            return .timeout(arguments: arguments)
        case .nonZeroExit(let status, let stderr):
            return .nonZeroExit(status: status, stderr: stderr)
        }
    }

    /// Naive shell tokenizer. Good enough for cmux-controlled command strings
    /// (panel cmd captured via OSC 7 + cwd snapshot). Doesn't try to be a
    /// full parser; users with quoting needs should pass an array directly
    /// at the call site (Phase 4 will).
    static func tokenizeShell(_ s: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quote: Character?
        for c in s {
            if let q = quote {
                if c == q {
                    quote = nil
                } else {
                    current.append(c)
                }
                continue
            }
            switch c {
            case "\"", "'":
                quote = c
            case " ", "\t":
                if !current.isEmpty {
                    args.append(current)
                    current = ""
                }
            default:
                current.append(c)
            }
        }
        if !current.isEmpty { args.append(current) }
        return args
    }

    static func parseWorktreeList(_ raw: String) -> [DaemonWorktree] {
        // tsm wt prints one worktree per line; format may include path +
        // branch + session counts. We fall back to a tolerant split: take
        // the first whitespace-separated token as the branch name.
        return raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .compactMap { line -> DaemonWorktree? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty,
                      !trimmed.lowercased().hasPrefix("branch"),
                      !trimmed.lowercased().hasPrefix("no worktrees") else {
                    return nil
                }
                let token = trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
                guard let branch = token, !branch.isEmpty else { return nil }
                return DaemonWorktree(branch: branch, path: "", sessionNames: [])
            }
    }
}
