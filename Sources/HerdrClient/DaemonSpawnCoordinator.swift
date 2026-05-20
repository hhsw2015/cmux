import Darwin
import Foundation

/// Serializes `herdr-cmux server` spawns per-socket so two concurrent
/// callers from cmux's various herdr entry points don't both try to
/// boot the same daemon. The first caller into a given socket path
/// kicks off the spawn + socket-poll; later callers awaiting the same
/// path attach to that in-flight Task and share its outcome.
///
/// `Task.sleep` is used for polling so we never block the calling
/// thread (the previous `Thread.sleep` froze MainActor for up to 3 s
/// when the local daemon wasn't already running).
actor DaemonSpawnCoordinator {
    static let shared = DaemonSpawnCoordinator()

    enum SpawnError: Error, LocalizedError {
        case daemonExitedDuringStartup(status: Int32, stderr: String)
        case socketDidNotAppear(path: String)

        var errorDescription: String? {
            switch self {
            case .daemonExitedDuringStartup(let s, let stderr):
                let detail = stderr.isEmpty ? "" : " — \(stderr)"
                return "Local cmux agent exited (status \(s))\(detail)"
            case .socketDidNotAppear(let path):
                return "Local cmux agent didn't open its socket at \(path)"
            }
        }
    }

    /// In-flight spawn operations, keyed by socket path. We dedupe on
    /// path rather than session name so two HerdrBackend instances
    /// pointed at the same session converge cleanly.
    private var inFlight: [String: Task<Void, Error>] = [:]

    private init() {}

    func spawnIfNeeded(
        socketPath: String,
        executablePath: String,
        sessionName: String
    ) async throws {
        if FileManager.default.fileExists(atPath: socketPath) {
            // Detect a STALE socket: file exists but no daemon is
            // listening (e.g. previous daemon crashed without unlinking
            // the socket node). connect(2) with EOF/refused → unlink
            // and respawn. This is the path that caused users to see
            // "socketWrite(32)" / EPIPE on retry.
            if Self.isSocketAlive(at: socketPath) {
                return
            }
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        if let existing = inFlight[socketPath] {
            try await existing.value
            return
        }
        let task = Task<Void, Error> {
            try await Self.spawnAndWait(
                socketPath: socketPath,
                executablePath: executablePath,
                sessionName: sessionName
            )
        }
        inFlight[socketPath] = task
        defer { inFlight[socketPath] = nil }
        try await task.value
    }

    /// Quick non-blocking probe to tell apart a live UDS server from a
    /// stale socket node left behind by a crashed daemon. Returns true
    /// if connect(2) succeeds within 100ms.
    private static func isSocketAlive(at path: String) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < cap else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: cap) { rebound in
                for i in 0..<pathBytes.count {
                    rebound[i] = CChar(bitPattern: pathBytes[i])
                }
                rebound[pathBytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, len)
            }
        }
        return rc == 0
    }

    /// Spawn the daemon, redirect stderr to a Pipe so we can echo a
    /// crash reason back, and poll for the socket file. Times out at
    /// 3 s. If the daemon exits before the socket appears, surface the
    /// status + first ~256 bytes of stderr.
    private static func spawnAndWait(
        socketPath: String,
        executablePath: String,
        sessionName: String
    ) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = ["--session", sessionName, "server"]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        try proc.run()

        // Poll every 50 ms with `Task.sleep` so we yield instead of
        // freezing the caller's thread.
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath) {
                return
            }
            if !proc.isRunning {
                let stderr = readAvailable(stderrPipe.fileHandleForReading, max: 256)
                throw SpawnError.daemonExitedDuringStartup(
                    status: proc.terminationStatus,
                    stderr: stderr
                )
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if FileManager.default.fileExists(atPath: socketPath) {
            return
        }
        throw SpawnError.socketDidNotAppear(path: socketPath)
    }

    private static func readAvailable(_ handle: FileHandle, max: Int) -> String {
        let data = handle.availableData
        let bytes = data.prefix(max)
        return String(data: bytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
