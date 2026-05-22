import Foundation
import UserNotifications

/// Pushes the local `herdr-cmux` binary to a remote SSH host's
/// `~/.local/bin/herdr-cmux` so dogfooding doesn't require manual
/// rsync. Verifies success with `herdr-cmux --version` over the same
/// SSH connection. Trace output goes to /tmp/herdr-debug.log so the
/// user can see progress without an in-app dialog.
@MainActor
enum HerdrRemoteInstaller {
    /// Install on the first non-localhost host registered in the host
    /// registry. Useful as a menu one-liner.
    static func installOnFirstRemoteHost() {
        let remoteHost = HostRegistry.shared.hosts.first { host in
            if case .sshStdio = host.transport { return true }
            return false
        }
        guard let host = remoteHost else {
            herdrInstallerTrace("no remote host registered (Settings → Hosts)")
            return
        }
        installOnHost(host)
    }

    /// Install on the given host. No-op for `.localUDS`. For
    /// `.sshStdio`, kicks off a background scp+verify via the same
    /// path the menu uses. Used by the Settings → Hosts add flow to
    /// auto-deploy at host-registration time.
    /// Source repo for the herdr-cmux binary release. Always pulls
    /// `releases/latest/download/<asset>` so newly published tags are
    /// picked up automatically — no version pin maintenance required.
    static let releaseRepoOwner = "hhsw2015"
    static let releaseRepoName = "herdr"

    static func installOnHost(_ host: HerdrHost) {
        guard case .sshStdio = host.transport else {
            herdrInstallerTrace("\(host.displayName): nothing to install for local transport")
            return
        }
        Task.detached {
            await install(host: host)
        }
    }

    private static func install(host: HerdrHost) async {
        let target: String
        if case .sshStdio(let t, _, _, _, _) = host.transport {
            target = t
        } else {
            return
        }
        // 1. Detect remote OS+arch so we know which release asset to fetch.
        guard let assetName = detectRemoteAsset(host: host) else {
            await MainActor.run {
                herdrInstallerTrace("\(target): could not detect remote OS/arch")
                postNotification(
                    title: String(localized: "herdr.install.failed.title", defaultValue: "Set up failed"),
                    body: String(localized: "herdr.install.failed.unsupported", defaultValue: "\(target): unsupported remote OS or architecture")
                )
            }
            return
        }
        herdrInstallerTrace("\(target): detected asset \(assetName)")

        // 2. Skip download when remote already has herdr-cmux installed.
        //    The user can wipe the binary if they want to force-upgrade;
        //    re-installing on every "Set up" press is wasteful and trips
        //    over Text file busy when the daemon is running.
        let preexisting = captureSSH(
            host: host,
            command: "~/.local/bin/herdr-cmux --version 2>/dev/null"
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let skipDownload = preexisting.hasPrefix("herdr ")
        if skipDownload {
            herdrInstallerTrace("\(target): reusing existing \(preexisting)")
        } else {
            // Stage to a temp file then atomic-rename. Linux rejects writes
            // to a running executable ("Text file busy"); a rename swaps
            // the inode without disturbing any in-flight process. Only
            // taken when no working binary is on disk; reinstalls keep the
            // fast path above.
            let url = "https://github.com/\(releaseRepoOwner)/\(releaseRepoName)/releases/latest/download/\(assetName)"
            let installCmd = """
            mkdir -p ~/.local/bin && \
            TMP="$HOME/.local/bin/.herdr-cmux.new.$$" && \
            if command -v curl >/dev/null 2>&1; then \
              curl -fSL --retry 2 -o "$TMP" '\(url)'; \
            elif command -v wget >/dev/null 2>&1; then \
              wget -q -O "$TMP" '\(url)'; \
            else \
              echo 'no curl or wget on remote' >&2; exit 1; \
            fi && \
            chmod +x "$TMP" && \
            mv -f "$TMP" "$HOME/.local/bin/herdr-cmux"
            """
            if !runSSH(host: host, command: installCmd) {
                await MainActor.run {
                    herdrInstallerTrace("\(target): download failed")
                    postNotification(
                        title: String(localized: "herdr.install.failed.title", defaultValue: "Set up failed"),
                        body: String(localized: "herdr.install.failed.download", defaultValue: "\(target): could not download \(assetName) from latest release")
                    )
                }
                return
            }
        }
        // 3. Verify with --version.
        let version = captureSSH(
            host: host,
            command: "~/.local/bin/herdr-cmux --version"
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if version.isEmpty {
            await MainActor.run {
                herdrInstallerTrace("\(target): verification failed (no --version output)")
                HostHealthStore.shared.reportOffline(
                    hostId: host.id,
                    reason: String(localized: "herdr.err.installVerifyFailed",
                                   defaultValue: "Set up didn't finish — couldn't verify the cmux agent.")
                )
                postNotification(
                    title: String(localized: "herdr.install.failed.title", defaultValue: "Set up failed"),
                    body: String(localized: "herdr.install.failed.verify", defaultValue: "\(host.displayName): cmux agent didn't respond after install.")
                )
            }
            return
        }
        herdrInstallerTrace("\(target): installed \(version) (\(assetName))")

        // 4. Start the daemon for the configured session so api-bridge
        //    has a socket to talk to. The daemon is a TUI; we wrap it
        //    in `setsid -f script` to give it a pty without a real
        //    terminal. Idempotent — if it's already running, the
        //    existing process keeps the socket and the second invocation
        //    just exits.
        let session = host.sessionName
        guard isShellSafeSessionName(session) else {
            await MainActor.run {
                herdrInstallerTrace("\(target): refusing to start daemon — session name '\(session)' has shell-unsafe chars")
                postNotification(
                    title: String(localized: "herdr.install.failed.title", defaultValue: "Set up failed"),
                    body: String(localized: "herdr.install.failed.unsafeSession", defaultValue: "\(host.displayName): session name has unsupported characters. Use letters, digits, dashes, underscores, dots only.")
                )
            }
            return
        }
        let startCmd = """
        SOCK="$HOME/.config/herdr/sessions/\(session)/herdr.sock"; \
        if [ ! -S "$SOCK" ]; then \
          if command -v setsid >/dev/null 2>&1 && command -v script >/dev/null 2>&1; then \
            setsid -f script -q -c "$HOME/.local/bin/herdr-cmux --session \(session)" /dev/null \
              < /dev/null > /dev/null 2>&1 & \
          else \
            nohup "$HOME/.local/bin/herdr-cmux" --session \(session) \
              > /dev/null 2>&1 < /dev/null & \
          fi; \
          for _ in 1 2 3 4 5 6 7 8 9 10; do \
            sleep 1; \
            [ -S "$SOCK" ] && break; \
          done; \
        fi
        """
        if !runSSH(host: host, command: startCmd) {
            herdrInstallerTrace("\(target): daemon start command failed (may already be running)")
        }
        // Probe the api-bridge to confirm the socket is live.
        let pingResp = captureSSH(
            host: host,
            command: "printf '{\"id\":\"setup\",\"method\":\"ping\",\"params\":{}}\\n' | $HOME/.local/bin/herdr-cmux --session \(session) api-bridge 2>/dev/null"
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        await MainActor.run {
            if pingResp.contains("\"pong\"") {
                herdrInstallerTrace("\(target): daemon ready (session=\(session))")
                HostHealthStore.shared.reportOnline(hostId: host.id)
                postNotification(
                    title: String(localized: "herdr.install.success.title", defaultValue: "\(host.displayName) is ready"),
                    body: String(localized: "herdr.install.success.body", defaultValue: "Installed \(version).")
                )
            } else {
                herdrInstallerTrace("\(target): installed \(version) but daemon ping failed: \(pingResp.prefix(200))")
                HostHealthStore.shared.reportOffline(
                    hostId: host.id,
                    reason: String(localized: "herdr.err.daemonNotResponding",
                                   defaultValue: "Installed \(version) but the daemon didn't answer on session \(session).")
                )
                postNotification(
                    title: String(localized: "herdr.install.failed.title", defaultValue: "Set up failed"),
                    body: String(localized: "herdr.install.failed.daemon", defaultValue: "\(host.displayName): daemon didn't start. Run `~/.local/bin/herdr-cmux --session \(session)` manually in a terminal once.")
                )
            }
        }
    }

    /// Runs `uname -s` and `uname -m` on the remote and maps to a
    /// release asset name. Returns nil on unsupported combinations.
    private static func detectRemoteAsset(host: HerdrHost) -> String? {
        guard let raw = captureSSH(
            host: host,
            command: "printf '%s %s' \"$(uname -s)\" \"$(uname -m)\""
        )?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        let parts = raw.split(separator: " ").map(String.init)
        guard parts.count == 2 else { return nil }
        let os = parts[0].lowercased()
        let arch = parts[1].lowercased()
        switch (os, arch) {
        case ("linux", "x86_64"), ("linux", "amd64"):
            return "herdr-linux-x86_64"
        case ("linux", "aarch64"), ("linux", "arm64"):
            return "herdr-linux-aarch64"
        case ("darwin", "arm64"), ("darwin", "aarch64"):
            return "herdr-macos-aarch64"
        case ("darwin", "x86_64"):
            return "herdr-macos-x86_64"
        default:
            herdrInstallerTrace("unsupported remote: \(os)/\(arch)")
            return nil
        }
    }

    @MainActor
    private static func postNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: "cmux.herdr.install.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request) { _ in }
        }
    }

    private static func runSSH(host: HerdrHost, command: String) -> Bool {
        guard let invocation = SSHCommandBuilder.build(
            for: host, remoteCommand: [command]
        ) else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: invocation.executable)
        proc.arguments = invocation.args
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func captureSSH(host: HerdrHost, command: String) -> String? {
        guard let invocation = SSHCommandBuilder.build(
            for: host, remoteCommand: [command]
        ) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: invocation.executable)
        proc.arguments = invocation.args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// Session names that show up in shell scripts must be POSIX-safe
    /// without any quoting workarounds. Allow letters, digits, and the
    /// few separators herdr already accepts in session names.
    static func isShellSafeSessionName(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

private func herdrInstallerTrace(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] [HerdrRemoteInstaller] \(message)\n"
    if let data = line.data(using: .utf8) {
        if let handle = FileHandle(forWritingAtPath: "/tmp/herdr-debug.log") {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: "/tmp/herdr-debug.log", contents: data)
        }
    }
}
