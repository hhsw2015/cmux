import Foundation

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

    /// Spawn the subprocess. Throws if the binary isn't executable or
    /// the spawn itself fails. Bytes start flowing once herdr finishes
    /// the handshake server-side (typically within 100 ms locally).
    func start(takeover: Bool = false) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        var args: [String] = []
        if case .localUDS = host.transport {
            args += ["--session", host.sessionName]
        } else {
            // Remote transport — handled by HerdrBackend wrapping ssh.
            // For now this branch is unreachable since B4 handles localhost only.
            args += ["--session", host.sessionName]
        }
        args += ["raw-pty-attach", terminalId,
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
    /// bytes are queued on the subprocess stdin pipe.
    func send(_ bytes: Data) {
        guard let handle = stdinHandle else { return }
        do {
            try handle.write(contentsOf: bytes)
        } catch {
            // Pipe broken — process likely exited. Caller observes via
            // the output stream finishing.
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
