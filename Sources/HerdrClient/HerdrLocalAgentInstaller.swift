import AppKit
import Foundation

/// Mirrors HerdrRemoteInstaller's curl-from-release flow, but for the
/// local Mac. Runs when the user clicks "Install" on the missing-agent
/// alert: detects host architecture, downloads the matching macOS asset
/// from the herdr fork release, drops it at ~/.local/bin/herdr-cmux,
/// chmods +x, and verifies with --version.
///
/// Avoids the previous dead-end where users got an alert telling them
/// to "rebuild cmux from source" — most users won't / can't.
@MainActor
enum HerdrLocalAgentInstaller {
    static func installToUserBin() {
        Task.detached {
            await runInstall()
        }
    }

    private static func runInstall() async {
        let installPath = HerdrAgentPaths.userInstallPath
        let asset: String
        #if arch(arm64)
        asset = "herdr-macos-aarch64"
        #else
        asset = "herdr-macos-x86_64"
        #endif
        let url = "https://github.com/\(HerdrRemoteInstaller.releaseRepoOwner)/\(HerdrRemoteInstaller.releaseRepoName)/releases/latest/download/\(asset)"

        // mkdir -p ~/.local/bin && curl -fSL <url> -o ~/.local/bin/herdr-cmux && chmod +x
        let cmd = "/bin/sh"
        let script = """
        set -e
        mkdir -p "$HOME/.local/bin"
        if command -v curl >/dev/null 2>&1; then
          curl -fSL --retry 2 -o "\(installPath)" "\(url)"
        elif command -v wget >/dev/null 2>&1; then
          wget -q -O "\(installPath)" "\(url)"
        else
          echo "no curl or wget" >&2
          exit 1
        fi
        chmod +x "\(installPath)"
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cmd)
        proc.arguments = ["-c", script]
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        proc.standardOutput = FileHandle.nullDevice

        let success: Bool
        let stderrText: String
        do {
            try proc.run()
            proc.waitUntilExit()
            success = proc.terminationStatus == 0
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrText = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            success = false
            stderrText = String(describing: error)
        }

        await MainActor.run {
            let alert = NSAlert()
            if success && FileManager.default.isExecutableFile(atPath: installPath) {
                alert.alertStyle = .informational
                alert.messageText = String(
                    localized: "herdr.localInstall.success.title",
                    defaultValue: "cmux agent installed"
                )
                alert.informativeText = String(
                    localized: "herdr.localInstall.success.body",
                    defaultValue: "Installed \(asset) to \(installPath). Try opening a workspace again."
                )
            } else {
                alert.alertStyle = .warning
                alert.messageText = String(
                    localized: "herdr.localInstall.failed.title",
                    defaultValue: "Couldn't install cmux agent"
                )
                let detail = stderrText.isEmpty ? "" : "\n\n\(stderrText)"
                alert.informativeText = String(
                    localized: "herdr.localInstall.failed.body",
                    defaultValue: "cmux couldn't download \(asset) from the herdr release.\(detail)"
                )
            }
            alert.addButton(withTitle: String(
                localized: "herdr.localInstall.dismiss",
                defaultValue: "OK"
            ))
            alert.runModal()
        }
    }
}
