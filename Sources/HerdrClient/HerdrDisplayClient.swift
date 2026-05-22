import Foundation

/// Errors raised by HerdrDisplayClient.
enum HerdrDisplayClientError: Error, Equatable {
    /// Reserved for unsupported transport variants. SSH stdio is now
    /// supported via `ssh host -- herdr-cmux raw-pty-attach`; this
    /// case fires only if a new `HerdrHost.Transport` variant is
    /// added without display-client support.
    case remoteNotSupportedYet
    /// SSH command construction failed (non-sshStdio host slipped in).
    case spawnFailed(String)
}

/// Drives a herdr pane in RawPty mode by spawning the fork's
/// `raw-pty-attach` CLI subcommand and piping bytes both ways.
///
/// We don't speak bincode in Swift — the helper subprocess does the
/// bincode handshake / message framing internally and exposes a plain
/// stdio interface:
///
/// - subprocess STDOUT  =  raw PTY master bytes (RawPtyChunk payload)
/// - subprocess STDIN   =  keystroke bytes (sent as ClientMessage::Input)
///
/// Reconnect model: the public `output` AsyncStream is **long-lived**.
/// When the subprocess exits unexpectedly (network blip, ssh dropped,
/// daemon transient restart) the supervisor sleeps with backoff and
/// respawns with `--takeover`. Herdr's `subscribe_raw_pty_with_replay`
/// prepends the buffered history so the user sees what they missed.
/// The stream finishes only when the caller invokes `stop()`.
@MainActor
final class HerdrDisplayClient {
    /// Long-lived AsyncStream of raw PTY bytes from the herdr pane.
    /// Survives subprocess reconnects; finishes only on `stop()`.
    let output: AsyncStream<Data>

    /// Posted to NotificationCenter when reconnect state changes. The
    /// `userInfo` carries the new state under key `"state"`.
    static let reconnectStateChanged = Notification.Name("HerdrDisplayClient.reconnectStateChanged")

    enum ConnectionState: Equatable {
        case connecting
        case connected
        case reconnecting(attempt: Int)
        case stopped
    }

    private(set) var state: ConnectionState = .connecting {
        didSet {
            guard oldValue != state else { return }
            NotificationCenter.default.post(
                name: Self.reconnectStateChanged,
                object: self,
                userInfo: ["state": state]
            )
        }
    }

    private let outputContinuation: AsyncStream<Data>.Continuation
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var supervisor: Task<Void, Never>?
    private var stopped = false

    /// Cap on reconnect attempts before we give up and finish the
    /// output stream. With our 250ms→8s capped backoff, ~20 attempts
    /// covers ~2 minutes of outage — enough for typical SSH blips and
    /// daemon restarts but bounded for permanently deleted panes.
    private static let maxReconnectAttempts = 20

    let host: HerdrHost
    let terminalId: String
    let executablePath: String
    let initialCols: UInt16
    let initialRows: UInt16

    init(
        host: HerdrHost,
        terminalId: String,
        executablePath: String,
        cols: UInt16 = 80,
        rows: UInt16 = 24
    ) {
        self.host = host
        self.terminalId = terminalId
        self.executablePath = executablePath
        self.initialCols = cols
        self.initialRows = rows
        var continuation: AsyncStream<Data>.Continuation!
        self.output = AsyncStream(bufferingPolicy: .unbounded) { c in continuation = c }
        self.outputContinuation = continuation
    }

    /// Spawn the subprocess and start the supervisor. The first attach
    /// runs synchronously so callers can surface spawn-time errors;
    /// subsequent reconnects happen in the supervisor task.
    func start(takeover: Bool = false) async throws {
        try spawnAttach(takeover: takeover)
        state = .connected
        let initialPipes = currentPipes()
        startReader(initialPipes.stdout)
        observeTermination(stderr: initialPipes.stderr)
        supervisor = Task { [weak self] in
            await self?.superviseReconnects()
        }
    }

    /// Send keystroke bytes upstream to the pane. Drops bytes silently
    /// if no subprocess is currently connected (we're between attempts);
    /// herdr's replay restores screen state but cannot replay user
    /// input typed during the gap, which matches tmux/screen behavior.
    func send(_ bytes: Data) {
        guard let handle = stdinHandle else { return }
        do {
            try handle.write(contentsOf: bytes)
        } catch {
            NSLog("[HerdrDisplayClient] stdin write failed: %@",
                  String(describing: error))
        }
    }

    /// Tear down for good. Marks stopped so the supervisor exits, kills
    /// the subprocess, and finishes the output stream.
    func stop() {
        stopped = true
        supervisor?.cancel()
        supervisor = nil
        process?.terminate()
        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        outputContinuation.finish()
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        state = .stopped
    }

    // MARK: - private

    /// Fired by the reader task when stdout EOFs. Wakes the supervisor
    /// loop to attempt reconnect.
    private var disconnectSignal: AsyncStream<Void>.Continuation?
    private lazy var disconnectStream: AsyncStream<Void> = {
        var cont: AsyncStream<Void>.Continuation!
        let stream = AsyncStream<Void>(bufferingPolicy: .unbounded) { c in cont = c }
        self.disconnectSignal = cont
        return stream
    }()

    private func spawnAttach(takeover: Bool) throws {
        let proc = Process()
        var rawPtyArgs: [String] = ["--session", host.sessionName,
                                     "raw-pty-attach", terminalId,
                                     "--cols", String(initialCols),
                                     "--rows", String(initialRows)]
        if takeover { rawPtyArgs.append("--takeover") }
        switch host.transport {
        case .localUDS:
            proc.executableURL = URL(fileURLWithPath: executablePath)
            proc.arguments = rawPtyArgs
        case .sshStdio:
            let remoteBin = SSHCommandBuilder.remoteBinaryPath(for: host)
            var remoteCommand: [String] = [remoteBin]
            remoteCommand.append(contentsOf: rawPtyArgs)
            guard let invocation = SSHCommandBuilder.build(
                for: host, remoteCommand: remoteCommand
            ) else {
                throw HerdrDisplayClientError.spawnFailed("invalid sshStdio host")
            }
            proc.executableURL = URL(fileURLWithPath: invocation.executable)
            proc.arguments = invocation.args
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try proc.run()
        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
    }

    private func currentPipes() -> (stdout: FileHandle, stderr: FileHandle) {
        // Force-unwrap is safe immediately after a successful spawn.
        let stdout = stdoutHandle!
        let stderr = (process!.standardError as! Pipe).fileHandleForReading
        return (stdout, stderr)
    }

    /// Sleeps after disconnect, respawns, replumbs reader. Loops until
    /// `stop()` flips `stopped` (or the task is cancelled).
    private func superviseReconnects() async {
        for await _ in disconnectStream {
            if stopped { return }
            // Always reconnect with takeover so we win against any
            // straggler raw-pty-attach the daemon still has on file.
            // Cap at maxReconnectAttempts so a permanently deleted pane
            // doesn't spin a reconnect loop forever (each failed attempt
            // is a fresh SSH process). On exhaustion we finish the
            // stream so the panel pump exits and the panel goes inert.
            var attempt = 0
            var giveUp = false
            while !stopped && !Task.isCancelled {
                attempt += 1
                state = .reconnecting(attempt: attempt)
                let delayNs = backoffDelay(attempt: attempt)
                do {
                    try await Task.sleep(nanoseconds: delayNs)
                } catch {
                    return
                }
                if stopped || Task.isCancelled { return }
                do {
                    try spawnAttach(takeover: true)
                    let pipes = currentPipes()
                    startReader(pipes.stdout)
                    observeTermination(stderr: pipes.stderr)
                    state = .connected
                    break
                } catch {
                    NSLog(
                        "[HerdrDisplayClient] reconnect attempt %d failed: %@",
                        attempt, String(describing: error)
                    )
                    if attempt >= Self.maxReconnectAttempts {
                        giveUp = true
                        break
                    }
                    continue
                }
            }
            if giveUp {
                NSLog(
                    "[HerdrDisplayClient] giving up after %d reconnect attempts for terminal %@",
                    Self.maxReconnectAttempts, terminalId
                )
                outputContinuation.finish()
                state = .stopped
                return
            }
        }
    }

    private func backoffDelay(attempt: Int) -> UInt64 {
        // 250ms, 500ms, 1s, 2s, 4s, then cap at 8s.
        let capped = min(attempt, 6)
        let baseMs: UInt64 = 250 * (1 << UInt64(max(0, capped - 1)))
        let cappedMs = min(baseMs, 8000)
        return cappedMs * 1_000_000
    }

    private func startReader(_ handle: FileHandle) {
        let cont = outputContinuation
        let signal = disconnectSignal
        Task.detached(priority: .userInitiated) {
            while true {
                let data = handle.availableData
                if data.isEmpty {
                    // EOF on this attach — wake the supervisor to retry.
                    // Don't finish the public stream here; only stop()
                    // does that.
                    signal?.yield(())
                    return
                }
                cont.yield(data)
            }
        }
    }

    private func observeTermination(stderr handle: FileHandle) {
        guard let proc = process else { return }
        let signal = disconnectSignal
        proc.terminationHandler = { _ in
            signal?.yield(())
        }
        // Drain stderr so the subprocess never blocks on a full pipe;
        // surface unexpected stderr to the system log for diagnosis.
        Task.detached(priority: .utility) {
            let data = try? handle.readToEnd()
            if let data, !data.isEmpty,
               let text = String(data: data, encoding: .utf8) {
                NSLog("[HerdrDisplayClient] stderr: %@", text)
            }
        }
    }
}
