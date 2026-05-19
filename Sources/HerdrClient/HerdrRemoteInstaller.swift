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
    static func installOnHost(_ host: HerdrHost) {
        guard case .sshStdio(let target) = host.transport else {
            herdrInstallerTrace("\(host.displayName): nothing to install for local transport")
            return
        }
        let localBinary = (("~/.local/bin/herdr-cmux") as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: localBinary) else {
            herdrInstallerTrace("local binary missing at \(localBinary) — build the fork first")
            return
        }
        Task.detached {
            await install(target: target, localBinaryPath: localBinary)
        }
    }

    private static func install(target: String, localBinaryPath: String) async {
        // 1. Ensure ~/.local/bin exists on remote.
        if !runSSH(target: target, command: "mkdir -p ~/.local/bin") {
            await MainActor.run {
                herdrInstallerTrace("\(target): mkdir ~/.local/bin failed")
                postNotification(
                    title: String(localized: "herdr.install.failed.title", defaultValue: "Herdr install failed"),
                    body: String(localized: "herdr.install.failed.mkdir", defaultValue: "\(target): could not create ~/.local/bin")
                )
            }
            return
        }
        // 2. scp the binary.
        if !runSCP(localBinaryPath: localBinaryPath, target: target) {
            await MainActor.run {
                herdrInstallerTrace("\(target): scp failed")
                postNotification(
                    title: String(localized: "herdr.install.failed.title", defaultValue: "Herdr install failed"),
                    body: String(localized: "herdr.install.failed.scp", defaultValue: "\(target): scp transfer failed")
                )
            }
            return
        }
        // 3. chmod +x just in case scp didn't preserve permissions.
        _ = runSSH(target: target, command: "chmod +x ~/.local/bin/herdr-cmux")
        // 4. Verify with --version.
        let version = captureSSH(
            target: target,
            command: "~/.local/bin/herdr-cmux --version"
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        await MainActor.run {
            if version.isEmpty {
                herdrInstallerTrace("\(target): verification failed (no --version output)")
                postNotification(
                    title: String(localized: "herdr.install.failed.title", defaultValue: "Herdr install failed"),
                    body: String(localized: "herdr.install.failed.verify", defaultValue: "\(target): herdr-cmux --version returned no output")
                )
            } else {
                herdrInstallerTrace("\(target): installed \(version)")
                postNotification(
                    title: String(localized: "herdr.install.success.title", defaultValue: "Herdr installed"),
                    body: String(localized: "herdr.install.success.body", defaultValue: "\(target): \(version)")
                )
            }
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

    private static func runSSH(target: String, command: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ["-T", "-o", "BatchMode=yes", target, command]
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func captureSSH(target: String, command: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ["-T", "-o", "BatchMode=yes", target, command]
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

    private static func runSCP(localBinaryPath: String, target: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        proc.arguments = [
            "-o", "BatchMode=yes",
            localBinaryPath,
            "\(target):.local/bin/herdr-cmux",
        ]
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
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
