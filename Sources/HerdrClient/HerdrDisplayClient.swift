import Foundation

/// Errors raised by HerdrDisplayClient.
enum HerdrDisplayClientError: Error, Equatable {
    /// Reserved for unsupported transport variants.
    case remoteNotSupportedYet
    /// SSH command construction failed (non-sshStdio host slipped in).
    case spawnFailed(String)
}

/// One running raw-pty-attach subprocess and the file handles we use
/// to talk to it. Returned by the spawn closure so HerdrDisplayClient
/// stays decoupled from how the subprocess is created — production code
/// uses the Process-based default; tests inject a closure that wires
/// real Pipes to a no-op /bin/sleep process so they can simulate EOF
/// and reconnect timing without an SSH bridge or a herdr daemon.
struct HerdrDisplaySpawnHandle {
    let process: Process
    let stdin: FileHandle
    let stdout: FileHandle
    let stderr: FileHandle
}

/// Drives a herdr pane in RawPty mode by spawning the fork's
/// `raw-pty-attach` CLI subcommand and piping bytes both ways.
///
/// - subprocess STDOUT  =  raw PTY master bytes
/// - subprocess STDIN   =  keystroke bytes
///
/// Reconnect model: `output` is a long-lived AsyncStream; the supervisor
/// task respawns `raw-pty-attach --takeover` after subprocess EOF, with
/// 250ms→8s capped backoff. The stream finishes only when the caller
/// invokes `stop()` or after `maxReconnectAttempts` consecutive failed
/// spawns. Herdr's `subscribe_raw_pty_with_replay` prepends history on
/// reconnect so the user sees what they missed during the gap.
///
/// Threading:
/// - Public surface is @MainActor — call `start`/`send`/`stop` from the
///   main actor only.
/// - The supervisor task runs `Task.detached` so the synchronous
///   `Process.run()` (which can take seconds for a cold SSH handshake)
///   never blocks the main thread. State writes hop back via
///   `MainActor.run`.
/// - The reader task is also detached and signals EOF through the
///   disconnect stream, which is buffered with `.bufferingNewest(1)` so
///   a duplicate signal from `terminationHandler` doesn't kick a second
///   spurious reconnect attempt with takeover.
@MainActor
final class HerdrDisplayClient {
    typealias SpawnFunc = @Sendable (_ takeover: Bool) async throws -> HerdrDisplaySpawnHandle

    /// Long-lived AsyncStream of raw PTY bytes from the herdr pane.
    /// Survives subprocess reconnects; finishes only on stop() or
    /// reconnect-attempt exhaustion.
    let output: AsyncStream<Data>

    /// Posted to NotificationCenter when reconnect state changes.
    /// `userInfo["state"]` carries the new ConnectionState.
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

    /// Cap on consecutive failed reconnect spawns. With our backoff
    /// (250ms→8s capped) 20 attempts cover ~2 min of outage. After
    /// that we give up, finish the output stream, and let the panel go
    /// inert; user reopens to retry.
    static let maxReconnectAttempts = 20

    let host: HerdrHost
    let terminalId: String
    let executablePath: String
    let initialCols: UInt16
    let initialRows: UInt16

    private let spawn: SpawnFunc
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let disconnectStream: AsyncStream<Void>
    private let disconnectSignal: AsyncStream<Void>.Continuation

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var supervisor: Task<Void, Never>?

    /// Set to true by `stop()`. Read on every supervisor-loop boundary
    /// so a stop() racing a mid-flight spawn aborts cleanly without
    /// leaking a freshly-spawned subprocess.
    private var stopped = false

    /// Designated init. Pass a custom `spawn` closure to swap out the
    /// subprocess for a fake (used by HerdrDisplayClientTests).
    init(
        host: HerdrHost,
        terminalId: String,
        executablePath: String,
        cols: UInt16 = 80,
        rows: UInt16 = 24,
        spawn: SpawnFunc? = nil
    ) {
        self.host = host
        self.terminalId = terminalId
        self.executablePath = executablePath
        self.initialCols = cols
        self.initialRows = rows
        var outCont: AsyncStream<Data>.Continuation!
        self.output = AsyncStream(bufferingPolicy: .unbounded) { c in outCont = c }
        self.outputContinuation = outCont
        // .bufferingNewest(1) coalesces duplicate disconnect signals so
        // the supervisor doesn't take two reconnect trips per blip.
        var sigCont: AsyncStream<Void>.Continuation!
        self.disconnectStream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { c in sigCont = c }
        self.disconnectSignal = sigCont
        self.spawn = spawn ?? Self.defaultSpawn(
            host: host,
            terminalId: terminalId,
            executablePath: executablePath,
            cols: cols,
            rows: rows
        )
    }

    /// Spawn the first subprocess and start the supervisor. The first
    /// attach awaits inline so callers can surface spawn-time errors;
    /// subsequent reconnects happen in the supervisor task.
    func start(takeover: Bool = false) async throws {
        let handle = try await spawn(takeover)
        adopt(handle: handle)
        state = .connected
        supervisor = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runSupervisor()
        }
    }

    /// Send keystroke bytes upstream. No-op when the subprocess is dead
    /// or between reconnect attempts: writing to a closed pipe throws
    /// EPIPE and we'd just log noise. Herdr's replay restores the
    /// screen on reconnect; user input typed during the gap is lost,
    /// matching tmux/screen behavior on detach.
    func send(_ bytes: Data) {
        guard let handle = stdinHandle else { return }
        do {
            try handle.write(contentsOf: bytes)
        } catch {
            // Pipe broken — null the handle so subsequent send()s
            // exit early instead of writing to a corpse.
            stdinHandle = nil
            NSLog("[HerdrDisplayClient] stdin write failed: %@",
                  String(describing: error))
        }
    }

    /// Tear down for good. Marks stopped so the supervisor loop exits,
    /// kills the subprocess, finishes the output stream.
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

    private func adopt(handle: HerdrDisplaySpawnHandle) {
        process = handle.process
        stdinHandle = handle.stdin
        stdoutHandle = handle.stdout
        startReader(handle.stdout)
        observeTermination(process: handle.process, stderr: handle.stderr)
    }

    private func startReader(_ handle: FileHandle) {
        let cont = outputContinuation
        let signal = disconnectSignal
        Task.detached(priority: .userInitiated) {
            while true {
                let data = handle.availableData
                if data.isEmpty {
                    // EOF on this attach. Wake the supervisor; the
                    // public stream is NOT finished here — only stop()
                    // or attempt-exhaustion finish it.
                    signal.yield(())
                    return
                }
                cont.yield(data)
            }
        }
    }

    private func observeTermination(process proc: Process, stderr handle: FileHandle) {
        let signal = disconnectSignal
        proc.terminationHandler = { _ in
            // .bufferingNewest(1) on disconnectStream coalesces this
            // with the reader's EOF yield, so a single subprocess
            // death produces a single supervisor wake-up.
            signal.yield(())
        }
        // Drain stderr so the subprocess never blocks on a full pipe;
        // surface unexpected stderr to the system log.
        Task.detached(priority: .utility) {
            let data = try? handle.readToEnd()
            if let data, !data.isEmpty,
               let text = String(data: data, encoding: .utf8) {
                NSLog("[HerdrDisplayClient] stderr: %@", text)
            }
        }
    }

    private func runSupervisor() async {
        for await _ in disconnectStream {
            let alreadyStopped = await MainActor.run { self.stopped }
            if alreadyStopped { return }
            await MainActor.run {
                // Old subprocess is dead; null the handles so any
                // racing send() doesn't write to a corpse.
                self.stdinHandle = nil
                self.process = nil
            }
            var attempt = 0
            var giveUp = false
            while !Task.isCancelled {
                attempt += 1
                let nowStopped = await MainActor.run { self.stopped }
                if nowStopped { return }
                await MainActor.run { self.state = .reconnecting(attempt: attempt) }
                do {
                    try await Task.sleep(nanoseconds: Self.backoffDelay(attempt: attempt))
                } catch {
                    return
                }
                if Task.isCancelled { return }
                do {
                    let handle = try await self.spawn(true)
                    // Stop racing in: if the user closed the panel
                    // while we were spawning, terminate the just-born
                    // process and exit.
                    let raceStop = await MainActor.run { self.stopped }
                    if raceStop {
                        handle.process.terminate()
                        return
                    }
                    await MainActor.run {
                        self.adopt(handle: handle)
                        self.state = .connected
                    }
                    break
                } catch {
                    NSLog("[HerdrDisplayClient] reconnect attempt %d failed: %@",
                          attempt, String(describing: error))
                    if attempt >= Self.maxReconnectAttempts {
                        giveUp = true
                        break
                    }
                }
            }
            if giveUp {
                NSLog("[HerdrDisplayClient] giving up after %d reconnect attempts for terminal %@",
                      Self.maxReconnectAttempts, terminalId)
                await MainActor.run {
                    self.outputContinuation.finish()
                    self.state = .stopped
                }
                return
            }
        }
    }

    static func backoffDelay(attempt: Int) -> UInt64 {
        // 250ms, 500ms, 1s, 2s, 4s, then cap at 8s.
        let capped = min(attempt, 6)
        let baseMs: UInt64 = 250 * (1 << UInt64(max(0, capped - 1)))
        return min(baseMs, 8000) * 1_000_000
    }

    /// Production spawn closure: builds the raw-pty-attach Process and
    /// runs it. Tests bypass this via the `spawn:` parameter.
    private static func defaultSpawn(
        host: HerdrHost,
        terminalId: String,
        executablePath: String,
        cols: UInt16,
        rows: UInt16
    ) -> SpawnFunc {
        return { takeover in
            let proc = Process()
            var rawPtyArgs: [String] = ["--session", host.sessionName,
                                         "raw-pty-attach", terminalId,
                                         "--cols", String(cols),
                                         "--rows", String(rows)]
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
            return HerdrDisplaySpawnHandle(
                process: proc,
                stdin: stdinPipe.fileHandleForWriting,
                stdout: stdoutPipe.fileHandleForReading,
                stderr: stderrPipe.fileHandleForReading
            )
        }
    }
}
