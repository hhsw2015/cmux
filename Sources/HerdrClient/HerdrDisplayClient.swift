import Foundation

/// Errors raised by HerdrDisplayClient.
enum HerdrDisplayClientError: Error, Equatable {
    /// `host.transport` is not `.localUDS`. SSH stdio transport for the
    /// display path is implemented in B7.
    case remoteNotSupportedYet
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
/// PoC scope: no resize signaling. Initial size fixed at the cols/rows
/// passed at spawn. A follow-up will add a control fd.
@MainActor
final class HerdrDisplayClient {
    /// AsyncStream of raw PTY bytes from the herdr pane. Consumer feeds
    /// these into a Ghostty surface.
    let output: AsyncStream<Data>

    private let outputContinuation: AsyncStream<Data>.Continuation
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?

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
        self.output = AsyncStream { c in continuation = c }
        self.outputContinuation = continuation
    }

    /// Spawn the subprocess. Throws if the binary isn't executable, the
    /// spawn itself fails, or the host is not a local-UDS host (remote
    /// .sshStdio support is wired up in B7). Bytes start flowing once
    /// herdr finishes the handshake server-side (typically within
    /// ~100 ms locally).
    func start(takeover: Bool = false) async throws {
        guard case .localUDS = host.transport else {
            throw HerdrDisplayClientError.remoteNotSupportedYet
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        var args: [String] = ["--session", host.sessionName,
                              "raw-pty-attach", terminalId,
                              "--cols", String(initialCols),
                              "--rows", String(initialRows)]
        if takeover { args.append("--takeover") }
        proc.arguments = args

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

        startReader(stdoutPipe.fileHandleForReading)
        observeTermination(stderrPipe.fileHandleForReading)
    }

    /// Send keystroke bytes upstream to the pane. Returns once the
    /// bytes are queued on the subprocess stdin pipe. Pipe-broken
    /// errors are logged at NSLog level so a wedged pane is visible
    /// in Console.app; the output AsyncStream will finish on EOF, so
    /// callers don't need to poll for failure.
    func send(_ bytes: Data) {
        guard let handle = stdinHandle else { return }
        do {
            try handle.write(contentsOf: bytes)
        } catch {
            NSLog("[HerdrDisplayClient] stdin write failed: %@",
                  String(describing: error))
        }
    }

    /// Tear down the subprocess and end the output stream.
    func stop() {
        process?.terminate()
        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        outputContinuation.finish()
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
    }

    // MARK: - private

    private func startReader(_ handle: FileHandle) {
        let cont = outputContinuation
        Task.detached(priority: .userInitiated) {
            while true {
                let data = handle.availableData
                if data.isEmpty {
                    cont.finish()
                    return
                }
                cont.yield(data)
            }
        }
    }

    private func observeTermination(_ stderrHandle: FileHandle) {
        guard let proc = process else { return }
        let cont = outputContinuation
        proc.terminationHandler = { _ in
            cont.finish()
        }
        // Drain stderr so the subprocess never blocks on a full pipe;
        // surface unexpected stderr to the system log for diagnosis.
        Task.detached(priority: .utility) {
            let data = try? stderrHandle.readToEnd()
            if let data, !data.isEmpty,
               let text = String(data: data, encoding: .utf8) {
                NSLog("[HerdrDisplayClient] stderr: %@", text)
            }
        }
    }
}
