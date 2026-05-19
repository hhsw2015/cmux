import Foundation

/// Transport over an SSH stdio bridge: `ssh <target> herdr-cmux
/// api-bridge` ferries JSON-RPC bytes between cmux and a remote
/// herdr daemon. Mirrors `LocalUDSTransport`'s contract — one process
/// per logical connection, one-line-then-close API socket semantics
/// preserved end to end.
///
/// The bridge subcommand on the remote side reads its own
/// HERDR_SESSION env var (set via `--session NAME` global flag) so
/// callers can pass `--session` either as a remote arg or by setting
/// `LANG`-style env via ssh's `SendEnv` / `AcceptEnv`.
actor SSHStdioTransport: HerdrTransport {
    private let target: String
    private let sessionName: String?
    private let remoteBinaryPath: String
    private let extraSSHOptions: [String]

    /// Default ssh options. ControlMaster lets the 30s polling
    /// + raw-pty-attach + api-bridge invocations to the same host
    /// reuse one TCP/auth handshake (60s persist) instead of paying
    /// the full SSH negotiation per call. cmsocket dir is created
    /// once on first use.
    static let defaultOptions: [String] = {
        let cmDir = (("~/.ssh") as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(
            atPath: cmDir, withIntermediateDirectories: true
        )
        return [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(cmDir)/cmux-cm-%C",
            "-o", "ControlPersist=60",
        ]
    }()

    private(set) var status: HerdrTransportStatus = .disconnected
    let incoming: AsyncStream<Data>
    private let incomingContinuation: AsyncStream<Data>.Continuation

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutTask: Task<Void, Never>?

    init(
        target: String,
        sessionName: String? = nil,
        remoteBinaryPath: String = "herdr-cmux",
        extraSSHOptions: [String] = SSHStdioTransport.defaultOptions
    ) {
        self.target = target
        self.sessionName = sessionName
        self.remoteBinaryPath = remoteBinaryPath
        self.extraSSHOptions = extraSSHOptions
        var continuation: AsyncStream<Data>.Continuation!
        self.incoming = AsyncStream { c in continuation = c }
        self.incomingContinuation = continuation
    }

    func connect() async throws {
        guard process == nil else {
            throw HerdrTransportError.alreadyConnected
        }
        status = .connecting

        let proc = Process()
        proc.launchPath = "/usr/bin/ssh"
        var args = extraSSHOptions
        args.append(target)
        if let session = sessionName {
            args.append("--")
            args.append(remoteBinaryPath)
            args.append("--session")
            args.append(session)
            args.append("api-bridge")
        } else {
            args.append("--")
            args.append(remoteBinaryPath)
            args.append("api-bridge")
        }
        proc.arguments = args

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            status = .error("ssh spawn failed: \(error)")
            throw HerdrTransportError.other("ssh spawn failed: \(error)")
        }

        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        status = .online

        startStdoutPump(handle: stdoutPipe.fileHandleForReading)
        // Stderr is best-effort: drain so the pipe doesn't block but
        // don't crash on it. Surfaced via #if DEBUG callers' logs.
        startStderrDrain(handle: stderrPipe.fileHandleForReading)
    }

    func send(_ data: Data) async throws {
        guard let stdin = stdinHandle else {
            throw HerdrTransportError.notConnected
        }
        let captured = data
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try stdin.write(contentsOf: captured)
                    cont.resume(returning: ())
                } catch {
                    cont.resume(throwing: HerdrTransportError.other("ssh stdin write: \(error)"))
                }
            }
        }
    }

    func close() async {
        stdinHandle?.closeFile()
        stdinHandle = nil
        process?.terminate()
        process = nil
        stdoutTask?.cancel()
        stdoutTask = nil
        incomingContinuation.finish()
        status = .disconnected
    }

    private func startStdoutPump(handle: FileHandle) {
        let cont = incomingContinuation
        stdoutTask = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty {
                    cont.finish()
                    return
                }
                cont.yield(chunk)
            }
            cont.finish()
        }
    }

    private func startStderrDrain(handle: FileHandle) {
        Task.detached(priority: .background) {
            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty { return }
                if let text = String(data: chunk, encoding: .utf8) {
                    sshTransportTrace(target: "stderr", message: text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
    }
}

private func sshTransportTrace(target: String, message: String) {
#if DEBUG
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] [SSHStdioTransport.\(target)] \(message)\n"
    if let data = line.data(using: .utf8) {
        if let handle = FileHandle(forWritingAtPath: "/tmp/herdr-debug.log") {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: "/tmp/herdr-debug.log", contents: data)
        }
    }
#endif
}
