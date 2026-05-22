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
        // Populate the session-discovery cache so the command palette
        // already has "Attach to herdr session 'X'" entries when the
        // user opens it for the first time. Cheap (one CLI shell-out)
        // and runs in parallel with the reattach burst.
        HerdrSessionDiscovery.shared.refresh()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            for host in HostRegistry.shared.hosts {
                let persisted = HerdrPersistence.shared
                    .entries(forHostSession: host.sessionName)
                if persisted.isEmpty { continue }
                // Don't passively respawn the daemon just because cmux
                // remembered a workspace from a previous session. If
                // the user shut the daemon down (`herdr session stop`
                // / `delete`) AutoReattach should be a no-op until
                // they explicitly open a workspace via the menu, not
                // silently bring the daemon back up + leak a
                // placeholder tab. SSH hosts skip the stat — their
                // socket lives on the remote filesystem.
                if case .localUDS = host.transport {
                    let socketPath = host.localApiSocketPath
                    if !FileManager.default.fileExists(atPath: socketPath) {
                        cmuxDebugLog(
                            "herdr.autoReattach: skipping \(host.displayName) — no daemon socket at \(socketPath)"
                        )
                        // Persistence pointed at a daemon that's gone.
                        // Drop the stale entry so future launches
                        // don't keep retrying.
                        HerdrPersistence.shared.clear(host: host)
                        continue
                    }
                }
                for entry in persisted {
                    // Skip per-entry if a binding for this exact
                    // (host, workspace, tab) already exists — covers
                    // the case where the user manually attached one
                    // workspace via the menu during the 3 s settle
                    // window. Other persisted entries should still
                    // reattach.
                    let alreadyBound = HerdrTabRegistry.shared.allBindings.contains {
                        $0.host.id == host.id
                            && $0.workspaceId == entry.workspaceId
                            && $0.tabId == entry.tabId
                    }
                    if alreadyBound {
                        cmuxDebugLog(
                            "herdr.autoReattach: \(host.displayName) → \(entry.workspaceId)/\(entry.tabId) already bound; skipping"
                        )
                        continue
                    }
                    if let cmuxId = entry.cmuxWorkspaceId {
                        cmuxDebugLog(
                            "herdr.autoReattach: rebinding cmux workspace \(cmuxId) for \(host.displayName) → \(entry.workspaceId)/\(entry.tabId)"
                        )
                        HerdrPanelOpener.openWorkspace(
                            host: host,
                            attachExistingHerdrWorkspaceId: entry.workspaceId,
                            reuseCmuxWorkspaceId: cmuxId
                        )
                    } else {
                        cmuxDebugLog(
                            "herdr.autoReattach: attaching \(host.displayName) → \(entry.workspaceId) (no cmux uuid)"
                        )
                        HerdrPanelOpener.openWorkspace(
                            host: host,
                            workspaceId: entry.workspaceId
                        )
                    }
                    // Yield between opens so each one's pane.attach +
                    // Ghostty surface mount finishes before the next
                    // one starts splitting the focused pane.
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }

            // Orphan cleanup: pre-reuse-path builds added a fresh
            // herdr-bound sibling on every launch; cmux's normal
            // workspace persistence kept saving them, so users
            // upgrading carry a chain of dead-stub workspaces with no
            // PTY behind them. After auto-reattach has bound the live
            // ones, close every workspace whose panels are all
            // process-exited TerminalPanels with no HerdrPanelRegistry
            // entry — that's the dead-stub signature.
            guard let tabManager = AppDelegate.shared?.tabManager else { return }
            let orphans = tabManager.tabs.filter { workspace in
                workspace.isDeadHerdrStub()
            }
            for orphan in orphans {
                cmuxDebugLog(
                    "herdr.autoReattach: closing orphan workspace \(orphan.id) — all panels are dead herdr stubs"
                )
                tabManager.closeWorkspace(orphan)
            }
        }
    }
}
