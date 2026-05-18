import Foundation

/// Launch-time hook that reopens the herdr workspace the user had
/// attached when cmux last quit. Mirrors the manual "Open Herdr
/// Workspace (localhost)" menu click; just runs it automatically so
/// `Cmd+Q` followed by relaunch lands the user back where they were.
@MainActor
enum HerdrAutoReattach {
    /// Run after the launch burst settles. Skips if the user already
    /// attached something during the launch window (so the menu still
    /// wins if they click it before this fires).
    static func runOnLaunch() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            guard HerdrTabRegistry.shared.allBindings.isEmpty else {
                cmuxDebugLog("herdr.autoReattach: skipping — already attached")
                return
            }

            for host in HostRegistry.shared.hosts {
                guard HerdrPersistence.shared
                    .entry(forHostSession: host.sessionName) != nil
                else { continue }
                cmuxDebugLog("herdr.autoReattach: opening \(host.displayName)")
                HerdrPanelOpener.openWorkspace(host: host)
                // Yield between hosts so each open's pane.attach +
                // Ghostty surface mount finishes before the next one
                // starts splitting the focused pane.
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
}
