import Foundation
import UserNotifications

/// First-time install of the `cmux-tmux` binary on an SSH host
/// that has been added with `.cmuxTmuxSSH` transport.
///
/// Mirrors `HerdrRemoteInstaller` for the cmux-tmux backend:
///   1. uname -s/-m to pick a release asset
///   2. skip download when remote already has cmux-tmux on PATH
///   3. curl/wget the asset from the cmux fork's GH releases
///   4. atomic-move into ~/.local/bin/cmux-tmux
///   5. verify with `--version` (cmux-tmux currently exits 0 even
///      without the flag, so we ping via `serve` is overkill —
///      `command -v` is the verification we run)
///
/// No daemon to start (unlike herdr-cmux). cmux-tmux is launched
/// per-connection by `CmuxTmuxStdioTransport.connect()` so the
/// installer's job ends after the binary is on disk + executable.
enum CmuxTmuxRemoteInstaller {
    /// Source repo for the cmux-tmux binary release. Always pulls
    /// `releases/latest/download/<asset>` so newly published tags
    /// are picked up automatically — no version-pin maintenance
    /// here. cmux-tmux ships from the same fork as cmux itself.
    static let releaseRepoOwner = "hhsw2015"
    static let releaseRepoName = "cmux"

    static func installOnHost(_ host: HerdrHost) {
        guard case .cmuxTmuxSSH = host.transport else {
            cmuxTmuxInstallerTrace(
                "\(host.displayName): nothing to install for non-SSH cmux-tmux transport"
            )
            return
        }
        Task.detached {
            await install(host: host)
        }
    }

    private static func install(host: HerdrHost) async {
        let target: String
        if case .cmuxTmuxSSH(let t, _, _, _, _) = host.transport {
            target = t
        } else {
            return
        }

        guard let assetName = detectRemoteAsset(host: host) else {
            await MainActor.run {
                cmuxTmuxInstallerTrace("\(target): could not detect remote OS/arch")
                postNotification(
                    title: String(
                        localized: "cmuxTmux.install.failed.title",
                        defaultValue: "Set up failed"
                    ),
                    body: String(
                        localized: "cmuxTmux.install.failed.unsupported",
                        defaultValue: "\(target): unsupported remote OS or architecture"
                    )
                )
            }
            return
        }
        cmuxTmuxInstallerTrace("\(target): detected asset \(assetName)")

        // Skip download if the remote already has cmux-tmux —
        // either system-wide or in ~/.local/bin from a previous
        // install. Same shell expression CmuxTmuxCommandBuilder
        // uses at runtime so we never disagree about which copy
        // is "the one".
        let hbin = CmuxTmuxCommandBuilder.defaultRemoteBinaryShellExpression
        let preexistingPath = captureSSH(
            host: host,
            command: "command -v cmux-tmux 2>/dev/null || ls -1 \(hbin) 2>/dev/null"
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let skipDownload = !preexistingPath.isEmpty
        if skipDownload {
            cmuxTmuxInstallerTrace("\(target): reusing existing \(preexistingPath)")
        } else {
            let url = "https://github.com/\(releaseRepoOwner)/\(releaseRepoName)" +
                      "/releases/latest/download/\(assetName)"
            let installCmd = """
            mkdir -p ~/.local/bin && \
            TMP="$HOME/.local/bin/.cmux-tmux.new.$$" && \
            if command -v curl >/dev/null 2>&1; then \
              curl -fSL --retry 2 -o "$TMP" '\(url)'; \
            elif command -v wget >/dev/null 2>&1; then \
              wget -q -O "$TMP" '\(url)'; \
            else \
              echo 'no curl or wget on remote' >&2; exit 1; \
            fi && \
            chmod +x "$TMP" && \
            mv -f "$TMP" "$HOME/.local/bin/cmux-tmux"
            """
            if !runSSH(host: host, command: installCmd) {
                await MainActor.run {
                    cmuxTmuxInstallerTrace("\(target): download failed")
                    postNotification(
                        title: String(
                            localized: "cmuxTmux.install.failed.title",
                            defaultValue: "Set up failed"
                        ),
                        body: String(
                            localized: "cmuxTmux.install.failed.download",
                            defaultValue: "\(target): could not download \(assetName) from latest release"
                        )
                    )
                }
                return
            }
        }

        // Verify the binary responds. cmux-tmux without args prints
        // a usage line on stderr and exits non-zero (per the bin's
        // main()). Use `serve` with a closed stdin so it accepts
        // EOF immediately, OR just check exec bit + presence.
        let verify = captureSSH(
            host: host,
            command: "test -x \(hbin) && echo OK || echo MISSING"
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard verify == "OK" else {
            await MainActor.run {
                cmuxTmuxInstallerTrace("\(target): verification failed")
                HostHealthStore.shared.reportOffline(
                    hostId: host.id,
                    reason: String(
                        localized: "cmuxTmux.err.installVerifyFailed",
                        defaultValue: "Set up didn't finish — couldn't verify cmux-tmux on the remote."
                    )
                )
                postNotification(
                    title: String(
                        localized: "cmuxTmux.install.failed.title",
                        defaultValue: "Set up failed"
                    ),
                    body: String(
                        localized: "cmuxTmux.install.failed.verify",
                        defaultValue: "\(host.displayName): cmux-tmux didn't respond after install."
                    )
                )
            }
            return
        }
        cmuxTmuxInstallerTrace("\(target): installed cmux-tmux (\(assetName)) — ready")
    }

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
            return "cmux-tmux-linux-x86_64"
        case ("linux", "aarch64"), ("linux", "arm64"):
            return "cmux-tmux-linux-aarch64"
        case ("darwin", "arm64"), ("darwin", "aarch64"):
            return "cmux-tmux-macos-aarch64"
        case ("darwin", "x86_64"):
            return "cmux-tmux-macos-x86_64"
        default:
            cmuxTmuxInstallerTrace("unsupported remote: \(os)/\(arch)")
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
                identifier: "cmux.cmuxTmux.install.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request) { _ in }
        }
    }

    private static func runSSH(host: HerdrHost, command: String) -> Bool {
        guard let invocation = sshInvocation(host: host, remoteCommand: [command]) else {
            return false
        }
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
        guard let invocation = sshInvocation(host: host, remoteCommand: [command]) else {
            return nil
        }
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

    /// SSHCommandBuilder.build only knows about `.sshStdio`. Wrap
    /// the bits we need for `.cmuxTmuxSSH` into the same shape so
    /// install/verify can shell-out without re-deriving cmux's
    /// SSH defaults.
    private static func sshInvocation(
        host: HerdrHost,
        remoteCommand: [String]
    ) -> (executable: String, args: [String])? {
        guard case .cmuxTmuxSSH(let target, let extraArgs, let skipDefault, let sshExe, _) =
            host.transport
        else {
            return nil
        }
        let executable = sshExe ?? "/usr/bin/ssh"
        var args: [String] = []
        if !skipDefault {
            args.append(contentsOf: SSHStdioTransport.defaultOptions)
        }
        args.append(contentsOf: extraArgs)
        args.append(target)
        if !remoteCommand.isEmpty {
            args.append("--")
            args.append(contentsOf: remoteCommand)
        }
        return (executable, args)
    }
}

private func cmuxTmuxInstallerTrace(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] [CmuxTmuxRemoteInstaller] \(message)\n"
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
