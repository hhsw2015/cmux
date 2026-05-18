import Foundation

/// Backend-agnostic identifier for the persistence engine cmux is talking to.
public enum SessionDaemonKind: String, Sendable, Codable {
    case zmx
    case tsm
    case herdr
}

/// Minimum capabilities every daemon backend must provide. Both `zmx` and
/// `tsm` implement this; cmux's binding/restore/badge code only depends on
/// the protocol so swapping engines is a one-line change at the resolver.
public protocol SessionDaemonBackend: Sendable {
    var kind: SessionDaemonKind { get }
    func locateBinary() -> URL?
    func version() -> String?
    func listSessions() async throws -> [DaemonSession]
    func isAlive(_ name: String) async -> Bool
    func kill(_ name: String, force: Bool) async throws
    func parseAttachInvocation(_ argv: [String]) -> ParsedDaemonAttach?
}

/// Optional richer surface: tsm implements this, zmx does not. Phase 4+
/// features (project save/open, branch switching, event stream) gate on
/// `backend as? DeepSessionDaemonBackend != nil`.
public protocol DeepSessionDaemonBackend: SessionDaemonBackend {
    func createSession(name: String, cmd: String, dir: String) async throws
    func detachSession(_ name: String) async throws
    func listWorktrees() async throws -> [DaemonWorktree]
    func createWorktree(branch: String, base: String?) async throws
    func switchWorktree(branch: String) async throws
    func deleteWorktree(branch: String) async throws
    /// nil → fall back to polling
    func eventStream() -> AsyncStream<DaemonEvent>?
}

// MARK: - shared models

public struct DaemonSession: Sendable, Equatable, Identifiable {
    public let name: String
    public let pid: Int32?
    public let cmd: String
    public let dir: String
    public let state: State
    public let clientCount: Int
    public let agentKind: String?

    public var id: String { name }

    public enum State: String, Sendable, Codable {
        case running
        case exited
        case detached
        case unknown
    }

    public init(
        name: String,
        pid: Int32?,
        cmd: String,
        dir: String,
        state: State,
        clientCount: Int,
        agentKind: String?
    ) {
        self.name = name
        self.pid = pid
        self.cmd = cmd
        self.dir = dir
        self.state = state
        self.clientCount = clientCount
        self.agentKind = agentKind
    }
}

public struct DaemonWorktree: Sendable, Equatable, Identifiable {
    public let branch: String
    public let path: String
    public let sessionNames: [String]
    public var id: String { branch }

    public init(branch: String, path: String, sessionNames: [String]) {
        self.branch = branch
        self.path = path
        self.sessionNames = sessionNames
    }
}

public struct ParsedDaemonAttach: Sendable, Equatable {
    public let sessionName: String
    public init(sessionName: String) {
        self.sessionName = sessionName
    }
}

public enum DaemonEvent: Sendable, Equatable {
    case sessionCreated(name: String, cmd: String, dir: String)
    case sessionExited(name: String, exitCode: Int)
    case sessionAttached(name: String, clientCount: Int)
    case sessionDetached(name: String, clientCount: Int)
    case sessionKilled(name: String)
    case worktreeCreated(branch: String, sessionNames: [String])
    case worktreeSwitched(from: String, to: String)
    case worktreeDeleted(branch: String)
    case agentStarted(session: String, kind: String)
    case agentCompleted(session: String, kind: String)
}

public enum SessionDaemonError: Error, Equatable {
    case binaryNotFound
    case notSupported(String)
    case timeout(arguments: [String])
    case nonZeroExit(status: Int32, stderr: String)
}
