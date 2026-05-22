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

    /// Background queue used to drain stdin writes off the main actor.
    /// `Pipe.fileHandleForWriting.write` is synchronous and blocks when
    /// the kernel buffer fills (typical macOS pipe is 16-64 KB) —
    /// large pastes over slow ssh would otherwise freeze the UI.
    private static let stdinQueue = DispatchQueue(
        label: "com.cmux.HerdrDisplayClient.stdin", qos: .userInitiated
    )

    /// Cumulative spawn-failure budget that survives the
    /// "successful reconnect that immediately dies again" flap loop.
    /// `attempt` resets to 0 on every outer disconnect, but
    /// `flapAttempts` only resets after the new attach has stayed
    /// connected longer than `minStableUptimeSeconds`.
    private var flapAttempts = 0
    private var lastConnectAt: Date?
    static let minStableUptimeSeconds: TimeInterval = 5

    /// Test-only inspector. Production code never reads stdinHandle
    /// directly — use `send` and rely on the post-EOF nil-out
    /// happening through the supervisor's MainActor.run hop. Tests
    /// look at this to lock the contract that send() during a
    /// reconnect window leaves the handle nil.
    var stdinHandleForTesting: FileHandle? { stdinHandle }

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
    /// Idempotent guard: calling start() twice is a programming error
    /// (would race two supervisors on one displayClient); we trap it
    /// in DEBUG and no-op in release.
    func start(takeover: Bool = false) async throws {
        assert(supervisor == nil, "HerdrDisplayClient.start() called twice")
        guard supervisor == nil else { return }
        let handle = try await spawn(takeover)
        adopt(handle: handle)
        state = .connected
        lastConnectAt = Date()
        supervisor = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runSupervisor()
        }
    }

    /// Send keystroke bytes upstream. No-op when the subprocess is dead
    /// or between reconnect attempts: writing to a closed pipe throws
    /// EPIPE and we'd just log noise. Herdr's replay restores the
    /// screen on reconnect; user input typed during the gap is lost,
    /// matching tmux/screen behavior on detach.
    ///
    /// The actual `handle.write` runs on a background queue. Pipe
    /// writes are synchronous and block when the kernel pipe buffer
    /// (16-64 KB typical) is full and the consumer is slow — pasting a
    /// few hundred KB into a wedged ssh would otherwise freeze the
    /// main thread.
    func send(_ bytes: Data) {
        guard let handle = stdinHandle else { return }
        Self.stdinQueue.async { [weak self] in
            do {
                try handle.write(contentsOf: bytes)
            } catch {
                NSLog("[HerdrDisplayClient] stdin write failed: %@",
                      String(describing: error))
                Task { @MainActor in
                    // Pipe broken — null the handle so subsequent
                    // send()s exit early instead of dispatching writes
                    // to a corpse.
                    if self?.stdinHandle === handle {
                        self?.stdinHandle = nil
                    }
                }
            }
        }
    }

    /// Tear down for good. Marks stopped so the supervisor loop exits,
    /// kills the subprocess, finishes the output stream.
    func stop() {
        stopped = true
        supervisor?.cancel()
        supervisor = nil
        // Detach terminationHandler BEFORE terminate() so the closure
        // doesn't fire after stop() finishes and yield a stale
        // disconnect signal that a future start() (if anyone adds one)
        // would consume by spawning a phantom subprocess.
        process?.terminationHandler = nil
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
            // Single hop: read stopped, decide flap budget, clear
            // handles atomically. Splitting these reads into separate
            // hops opens an interleaving window where stop() and the
            // supervisor partially trample each other's state.
            let pre: (stopped: Bool, flapped: Bool) = await MainActor.run {
                let wasFlap: Bool
                if let last = self.lastConnectAt,
                   Date().timeIntervalSince(last) < Self.minStableUptimeSeconds {
                    self.flapAttempts += 1
                    wasFlap = true
                } else {
                    self.flapAttempts = 0
                    wasFlap = false
                }
                // Clear handles so a racing send() doesn't write to a
                // corpse before we've spawned the replacement.
                self.stdinHandle = nil
                self.process = nil
                return (self.stopped, wasFlap)
            }
            if pre.stopped { return }

            var attempt = 0
            var giveUp = false
            while !Task.isCancelled {
                attempt += 1
                // Same single-hop pattern: read stopped + bump state.
                let stoppedNow: Bool = await MainActor.run {
                    if self.stopped { return true }
                    self.state = .reconnecting(attempt: attempt)
                    return false
                }
                if stoppedNow { return }

                // Cumulative cap: if we're flapping (lots of fast
                // disconnects), trip the cap on flapAttempts instead
                // of letting per-disconnect attempt resets perpetually
                // dodge it.
                let totalAttempts = await MainActor.run { self.flapAttempts + attempt }
                if totalAttempts > Self.maxReconnectAttempts {
                    giveUp = true
                    break
                }

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
                    let aborted: Bool = await MainActor.run {
                        if self.stopped { return true }
                        self.adopt(handle: handle)
                        self.state = .connected
                        self.lastConnectAt = Date()
                        return false
                    }
                    if aborted {
                        handle.process.terminate()
                        return
                    }
                    break
                } catch {
                    NSLog("[HerdrDisplayClient] reconnect attempt %d (cumulative %d) failed: %@",
                          attempt, totalAttempts, String(describing: error))
                    if totalAttempts >= Self.maxReconnectAttempts {
                        giveUp = true
                        break
                    }
                }
            }
            if giveUp {
                NSLog("[HerdrDisplayClient] giving up after cap reached for terminal %@", terminalId)
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
