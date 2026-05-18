import Foundation

/// `SessionDaemonBackend` implementation that proxies to the existing
/// `ZmxClient` / `ZmxLocator` / `ZmxArgvParser` types so cmux callers can
/// drop the legacy direct dependency without changing runtime behavior.
public struct ZmxBackend: SessionDaemonBackend {
    public let kind = SessionDaemonKind.zmx
    private let processTimeout: TimeInterval

    public init(processTimeout: TimeInterval = 3.0) {
        self.processTimeout = processTimeout
    }

    public func locateBinary() -> URL? {
        ZmxLocator.resolveBinary()
    }

    public func version() -> String? {
        guard let url = locateBinary() else { return nil }
        return ZmxLocator.version(at: url)
    }

    public func listSessions() async throws -> [DaemonSession] {
        guard let binary = locateBinary() else {
            throw SessionDaemonError.binaryNotFound
        }
        let client = ZmxClient(binaryPath: binary, processTimeout: processTimeout)
        return try await Task.detached(priority: .utility) {
            do {
                let names = try client.listAlive()
                return names.sorted().map { name in
                    DaemonSession(
                        name: name,
                        pid: nil,
                        cmd: "",
                        dir: "",
                        state: .running,
                        clientCount: 1,
                        agentKind: nil
                    )
                }
            } catch let error as ZmxClientError {
                throw Self.wrap(error)
            }
        }.value
    }

    public func isAlive(_ name: String) async -> Bool {
        guard let binary = locateBinary() else { return false }
        let client = ZmxClient(binaryPath: binary, processTimeout: processTimeout)
        return await Task.detached(priority: .utility) {
            client.isAlive(name)
        }.value
    }

    public func kill(_ name: String, force: Bool) async throws {
        guard let binary = locateBinary() else {
            throw SessionDaemonError.binaryNotFound
        }
        let client = ZmxClient(binaryPath: binary, processTimeout: processTimeout)
        try await Task.detached(priority: .utility) {
            do {
                try client.kill(name, force: force)
            } catch let error as ZmxClientError {
                throw Self.wrap(error)
            }
        }.value
    }

    public func parseAttachInvocation(_ argv: [String]) -> ParsedDaemonAttach? {
        guard let parsed = ZmxArgvParser.parse(argv) else { return nil }
        return ParsedDaemonAttach(sessionName: parsed.sessionName)
    }

    private static func wrap(_ error: ZmxClientError) -> SessionDaemonError {
        switch error {
        case .timeout(let arguments):
            return .timeout(arguments: arguments)
        case .nonZeroExit(let status, let stderr):
            return .nonZeroExit(status: status, stderr: stderr)
        }
    }
}
