#if DEBUG
import Foundation

/// Pushes the local `herdr-cmux` binary to a remote SSH host's
/// `~/.local/bin/herdr-cmux` so dogfooding doesn't require manual
/// rsync. Verifies success with `herdr-cmux --version` over the same
/// SSH connection. Trace output goes to /tmp/herdr-debug.log so the
/// user can see progress without an in-app dialog.
@MainActor
enum HerdrRemoteInstaller {
    /// Install on the first non-localhost host registered in the host
    /// registry. Useful as a debug-menu one-liner during F1 dogfood.
    static func installOnFirstRemoteHost() {
        let remoteHost = HostRegistry.shared.hosts.first { host in
            if case .sshStdio = host.transport { return true }
            return false
        }
        guard let host = remoteHost else {
            herdrInstallerTrace("no remote host registered (Settings → Hosts)")
            return
        }
        guard case .sshStdio(let target) = host.transport else { return }

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
            await MainActor.run { herdrInstallerTrace("\(target): mkdir ~/.local/bin failed") }
            return
        }
        // 2. scp the binary.
        if !runSCP(localBinaryPath: localBinaryPath, target: target) {
            await MainActor.run { herdrInstallerTrace("\(target): scp failed") }
            return
        }
        // 3. chmod +x just in case scp didn't preserve permissions.
        _ = runSSH(target: target, command: "chmod +x ~/.local/bin/herdr-cmux")
        // 4. Verify with --version.
        let version = captureSSH(
            target: target,
            command: "~/.local/bin/herdr-cmux --version"
        ) ?? "(unknown)"
        await MainActor.run {
            herdrInstallerTrace("\(target): installed \(version.trimmingCharacters(in: .whitespacesAndNewlines))")
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
#endif
