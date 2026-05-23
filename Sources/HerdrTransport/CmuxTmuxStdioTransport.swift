import Foundation

/// Transport that drives a `cmux-tmux serve` subprocess (the
/// Rust shim that translates the cmux pane protocol into tmux
/// commands). One process per logical connection, line-delimited
/// JSON-RPC over stdin/stdout — the same wire shape as
/// `SSHStdioTransport` so `HerdrApiClient` can consume it
/// unchanged.
///
/// Handles both transport flavours:
///
///   * `.cmuxTmuxLocal` — direct `Process` against `cmux-tmux`
///     on the local box. Drives the user's local tmux server.
///   * `.cmuxTmuxSSH`   — `ssh <target> cmux-tmux ...` to drive
///     the user's tmux on a remote box.
///
/// Both flavours share the body below; only the launch
/// invocation differs (built via `CmuxTmuxCommandBuilder`).
actor CmuxTmuxStdioTransport: HerdrTransport {
    private let host: HerdrHost

    private(set) var status: HerdrTransportStatus = .disconnected
    let incoming: AsyncStream<Data>
    private let incomingContinuation: AsyncStream<Data>.Continuation

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTail: String = ""
    private var explicitlyClosed: Bool = false

    init(host: HerdrHost) {
        self.host = host
        var continuation: AsyncStream<Data>.Continuation!
        self.incoming = AsyncStream { c in continuation = c }
        self.incomingContinuation = continuation
    }

    func connect() async throws {
        guard process == nil else {
            throw HerdrTransportError.alreadyConnected
        }
        status = .connecting

        guard let invocation = CmuxTmuxCommandBuilder.build(
            for: host,
            subArgs: ["serve"]
        ) else {
            throw HerdrTransportError.other(
                "non-cmuxTmux host given to CmuxTmuxStdioTransport"
            )
        }

        let proc = Process()
        proc.launchPath = invocation.executable
        proc.arguments = invocation.args

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        proc.terminationHandler = { [weak self] terminated in
            Task { [weak self] in
                await self?.handleProcessExit(
                    terminationStatus: terminated.terminationStatus,
                    reason: terminated.terminationReason
                )
            }
        }

        do {
            try proc.run()
        } catch {
            status = .error("cmux-tmux spawn failed: \(error)")
            throw HerdrTransportError.other("cmux-tmux spawn failed: \(error)")
        }

        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        status = .online
        explicitlyClosed = false
        stderrTail = ""

        startStdoutPump(handle: stdoutPipe.fileHandleForReading)
        startStderrDrain(handle: stderrPipe.fileHandleForReading)
    }

    private func handleProcessExit(
        terminationStatus: Int32,
        reason: Process.TerminationReason
    ) {
        if explicitlyClosed {
            return
        }
        let suffix = stderrTail.isEmpty ? "" : ": \(stderrTail)"
        let detail = reason == .uncaughtSignal
            ? "cmux-tmux died on signal (status=\(terminationStatus))\(suffix)"
            : "cmux-tmux exited \(terminationStatus)\(suffix)"
        status = .error(detail)
        cmuxTmuxTransportTrace(host: host.displayName, message: detail)
        incomingContinuation.finish()
        process = nil
        stdinHandle?.closeFile()
        stdinHandle = nil
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
                    cont.resume(throwing: HerdrTransportError.other(
                        "cmux-tmux stdin write: \(error)"
                    ))
                }
            }
        }
    }

    func close() async {
        explicitlyClosed = true
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
        Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty { return }
                if let text = String(data: chunk, encoding: .utf8) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        cmuxTmuxTransportTrace(
                            host: "stderr", message: trimmed
                        )
                        await self?.appendStderr(trimmed)
                    }
                }
            }
        }
    }

    private func appendStderr(_ line: String) {
        let combined = stderrTail.isEmpty ? line : "\(stderrTail) \(line)"
        if combined.count <= 512 {
            stderrTail = combined
        } else {
            stderrTail = String(combined.suffix(512))
        }
    }
}

private func cmuxTmuxTransportTrace(host: String, message: String) {
#if DEBUG
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] [CmuxTmuxStdioTransport.\(host)] \(message)\n"
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
