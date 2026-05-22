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
    private let host: HerdrHost
    private let target: String

    /// Always-good options that benefit every ssh launch (including
    /// sshpass-wrapped ones): ControlMaster reuse, keepalives, no-tty.
    /// These never break interactive auth, so they're injected even
    /// when the user pasted a sshpass command that needs a password.
    static let alwaysGoodOptions: [String] = {
        let cmDir = (("~/.ssh") as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(
            atPath: cmDir, withIntermediateDirectories: true
        )
        return [
            "-T",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(cmDir)/cmux-cm-%C",
            "-o", "ControlPersist=60",
        ]
    }()

    /// Non-interactive options. Skipped when a custom executable
    /// (sshpass) is in play — BatchMode=yes blocks the very password
    /// prompt sshpass relies on.
    static let nonInteractiveOptions: [String] = ["-o", "BatchMode=yes"]

    /// Combined defaults for the plain-ssh case. Kept as the public
    /// constant other callers (HerdrDisplayClient/HerdrRemoteInstaller)
    /// historically referenced.
    static var defaultOptions: [String] { alwaysGoodOptions + nonInteractiveOptions }

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
        if case .sshStdio(let target, _, _, _, _) = host.transport {
            self.target = target
        } else {
            // Defensive: caller should only construct this for sshStdio
            // hosts. Localhost goes through LocalUDSTransport.
            self.target = ""
        }
        var continuation: AsyncStream<Data>.Continuation!
        self.incoming = AsyncStream { c in continuation = c }
        self.incomingContinuation = continuation
    }

    func connect() async throws {
        guard process == nil else {
            throw HerdrTransportError.alreadyConnected
        }
        status = .connecting

        // Wrap api-bridge in a shell snippet that auto-spawns the
        // daemon if its socket is missing, so the user doesn't have
        // to ssh in by hand after a remote reboot or after `herdr
        // server stop`. Same logic the installer uses, just inline so
        // every reconnect heals.
        //
        // Falls back to bare api-bridge invocation when:
        //   - the user pinned a custom remote-binary path (we can't
        //     guess where their daemon lives in that case)
        //   - the session name has shell-unsafe chars (refusing
        //     interpolation matches the installer's policy)
        // In both fallback paths the user retains the manual setup
        // path; we just don't try to be clever.
        let remoteBinary = SSHCommandBuilder.remoteBinaryPath(for: host)
        // Default returns a shell expression we own; anything else
        // means the user pinned a custom path. Skip auto-spawn for
        // overridden paths since we can't safely guess where the
        // daemon's session dir lives in that case.
        let usesDefaultBinary = remoteBinary.contains("command -v herdr-cmux")
        let session = host.sessionName
        let canAutoSpawn = usesDefaultBinary
            && !session.isEmpty
            && SSHStdioTransport.isShellSafeSessionName(session)

        var remoteCommand: [String]
        if canAutoSpawn {
            remoteCommand = [Self.autoSpawnShellCommand(session: session)]
        } else {
            remoteCommand = [remoteBinary]
            if !session.isEmpty {
                remoteCommand.append("--session")
                remoteCommand.append(session)
            }
            remoteCommand.append("api-bridge")
        }

        guard let invocation = SSHCommandBuilder.build(
            for: host, remoteCommand: remoteCommand
        ) else {
            throw HerdrTransportError.other("non-sshStdio host given to SSHStdioTransport")
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

        // Termination handler: fires when ssh exits for any reason
        // (peer closed, network drop, auth failure, remote daemon
        // crash). Called on a background queue. Drive transport
        // status into .error and finish the incoming stream so the
        // event pump notices and runs its reconnect path. Skip when
        // the closure was triggered by an explicit close() call.
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
            status = .error("ssh spawn failed: \(error)")
            throw HerdrTransportError.other("ssh spawn failed: \(error)")
        }

        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        status = .online
        explicitlyClosed = false
        stderrTail = ""

        startStdoutPump(handle: stdoutPipe.fileHandleForReading)
        // Stderr is best-effort: drain so the pipe doesn't block but
        // don't crash on it. Surfaced via #if DEBUG callers' logs and
        // captured into stderrTail so terminationHandler can include
        // it in the error message.
        startStderrDrain(handle: stderrPipe.fileHandleForReading)
    }

    private func handleProcessExit(
        terminationStatus: Int32,
        reason: Process.TerminationReason
    ) {
        // Either close() was called (which sets explicitlyClosed and
        // already flipped status to .disconnected) or the process
        // died unexpectedly. In the unexpected case, surface a
        // structured error so the event pump can resurface it in
        // the host row.
        if explicitlyClosed {
            return
        }
        let suffix = stderrTail.isEmpty ? "" : ": \(stderrTail)"
        let detail = reason == .uncaughtSignal
            ? "ssh died on signal (status=\(terminationStatus))\(suffix)"
            : "ssh exited \(terminationStatus)\(suffix)"
        status = .error(detail)
        sshTransportTrace(target: target, message: detail)
        // End the incoming stream — the consumer's `for await` exits
        // and the pump retries with backoff.
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
                    cont.resume(throwing: HerdrTransportError.other("ssh stdin write: \(error)"))
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
        // Capture stderr tail so terminationHandler can surface
        // ssh's "Connection closed by remote host" / "Permission denied"
        // / "Could not resolve hostname" lines as the error reason.
        Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty { return }
                if let text = String(data: chunk, encoding: .utf8) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        sshTransportTrace(target: "stderr", message: trimmed)
                        await self?.appendStderr(trimmed)
                    }
                }
            }
        }
    }

    private func appendStderr(_ line: String) {
        // Keep only the most recent ~512 bytes; ssh stderr can be
        // chatty (banner, motd) but only the last lines are useful
        // when surfacing to UI.
        let combined = stderrTail.isEmpty ? line : "\(stderrTail) \(line)"
        if combined.count <= 512 {
            stderrTail = combined
        } else {
            stderrTail = String(combined.suffix(512))
        }
    }

    /// Allow only `[A-Za-z0-9_.-]` in a session name we're about to
    /// interpolate into a remote shell snippet. Same policy as the
    /// installer.
    static func isShellSafeSessionName(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// One-shot shell snippet that ensures the daemon for `session`
    /// is alive on the remote, then `exec`s `api-bridge` so the SSH
    /// stdio attaches directly. The `exec` matters: it replaces the
    /// shell with herdr-cmux so cmux's stdin/stdout pipes line up.
    ///
    /// Resolves the binary by `command -v herdr-cmux` first so a
    /// system-wide install (e.g. /usr/local/bin) works just like
    /// the user-local install we ship via the auto-installer.
    static func autoSpawnShellCommand(session: String) -> String {
        return """
        HBIN="$(command -v herdr-cmux 2>/dev/null)"; \
        [ -z "$HBIN" ] && [ -x "$HOME/.local/bin/herdr-cmux" ] && HBIN="$HOME/.local/bin/herdr-cmux"; \
        if [ -z "$HBIN" ]; then echo "herdr-cmux not found on remote PATH or ~/.local/bin" >&2; exit 127; fi; \
        SOCK="$HOME/.config/herdr/sessions/\(session)/herdr.sock"; \
        if [ -S "$SOCK" ]; then \
          ALIVE=0; \
          if command -v pgrep >/dev/null 2>&1; then \
            pgrep -f "herdr-cmux .*--session \(session)" >/dev/null 2>&1 && ALIVE=1; \
          elif [ -r /proc/net/unix ]; then \
            awk -v s="$SOCK" '$NF==s && $6=="01" {f=1} END{exit !f}' /proc/net/unix && ALIVE=1; \
          else \
            ALIVE=1; \
          fi; \
          [ "$ALIVE" = 0 ] && rm -f "$SOCK"; \
        fi; \
        if [ ! -S "$SOCK" ]; then \
          if command -v setsid >/dev/null 2>&1 && command -v script >/dev/null 2>&1; then \
            setsid -f script -q -c "$HBIN --session \(session)" /dev/null \
              < /dev/null > /dev/null 2>&1 & \
          else \
            nohup "$HBIN" --session \(session) \
              > /dev/null 2>&1 < /dev/null & \
          fi; \
          for _ in 1 2 3 4 5 6 7 8 9 10; do \
            sleep 1; \
            [ -S "$SOCK" ] && break; \
          done; \
        fi; \
        exec "$HBIN" --session \(session) api-bridge
        """
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
