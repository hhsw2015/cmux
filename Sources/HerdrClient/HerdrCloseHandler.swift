import Foundation

/// Handles cleanup when a herdr-backed terminal panel closes inside
/// cmux. Sends the matching `pane.close` RPC against the host that
/// owns the pane (tmux-style: closing a split kills the process), then
/// tears down the local registry entries so the display client and
/// io-callback box stop holding memory.
@MainActor
enum HerdrCloseHandler {
    /// Herdr pane ids whose corresponding cmux pane will be closed
    /// imminently as part of an inbound `LayoutChanged` reconcile.
    /// `handlePanelClosed` consumes these ids and skips the
    /// `pane.close` RPC for them — the remote already closed the pane,
    /// so echoing back would be wasted work and could race against
    /// other clients.
    static var suppressNextCloseFor: Set<String> = []

    /// Workspace ids currently being torn down as a detach (Cmd-W on a
    /// herdr-backed tab). When TabManager.closeWorkspace removes a
    /// herdr-backed workspace it adds the workspace id here so the
    /// per-panel `handlePanelClosed` calls treat the close as a detach
    /// even though the caller didn't pass `isDetach: true`. The set
    /// holds the cmux Workspace.id (UUID), not herdr's workspace_id.
    static var detachingWorkspaceIds: Set<UUID> = []

    /// Best-effort cleanup for a single closed panel. Safe to call for
    /// any panel — if the panel wasn't herdr-backed, this is a no-op.
    ///
    /// `isDetach: true` follows tmux semantics — local resources are
    /// torn down (display client stop, pump cancel, ctx release,
    /// binding unbind, registry remove) but the `pane.close` RPC is
    /// suppressed so the herdr daemon keeps the process alive for the
    /// next reattach. Cmd+Q and window close pass true; user-initiated
    /// per-pane / per-tab close passes false (default).
    static func handlePanelClosed(panelId: UUID, isDetach: Bool = false) {
        guard let entry = HerdrPanelRegistry.shared.entry(panelId: panelId) else {
            return
        }
        let herdrPaneId = entry.paneId
        let host = entry.host

        // Promote to detach if TabManager.closeWorkspace marked this
        // workspace as a detaching close. Without this promotion, Cmd-W
        // on a herdr-backed tab cascades pane.close RPCs that destroy
        // the daemon-side workspace + custom_name; the user wants close
        // to follow tmux detach semantics so the workspace persists.
        let workspaceTearingDown = HerdrTabRegistry.shared.allBindings.first(where: {
            $0.paneBindings.cmuxPaneId(forHerdrId: herdrPaneId) != nil
        })?.workspace?.id
        let effectiveDetach = isDetach
            || (workspaceTearingDown.map { detachingWorkspaceIds.contains($0) } ?? false)

        // Find any HerdrTabBinding that owned a cmux pane bound to this
        // herdr pane and drop the mapping so subsequent E2 mutation
        // lookups stop seeing a closed pane.
        for binding in HerdrTabRegistry.shared.allBindings {
            if binding.paneBindings.cmuxPaneId(forHerdrId: herdrPaneId) != nil {
                binding.paneBindings.unbind(herdrPaneId: herdrPaneId)
                if binding.paneBindings.count == 0 {
                    HerdrTabRegistry.shared.remove(key: binding.rootCmuxPaneId)
                    HerdrDividerSync.reset(bindingKey: binding.rootCmuxPaneId)
                    let bindingHost = binding.host
                    let bindingWorkspaceId = binding.workspaceId
                    let bindingTabId = binding.tabId
                    Task { await HerdrEventPump.shared.release(host: bindingHost) }
                    // Detach preserves the binding for next-launch reattach;
                    // explicit close drops it so we don't try to reattach
                    // a workspace the user just killed. Use clearOne so
                    // closing one bound cmux workspace doesn't nuke the
                    // persistence rows for the other workspaces still
                    // attached to the same host.
                    if !effectiveDetach {
                        HerdrPersistence.shared.clearOne(
                            host: bindingHost,
                            workspaceId: bindingWorkspaceId,
                            tabId: bindingTabId
                        )
                    }
                }
            }
        }

        // Tear down local resources first so we don't leak even if the
        // RPC dispatch hangs.
        HerdrPanelRegistry.shared.remove(panelId: panelId)

        // If the close came from an inbound LayoutChanged event, the
        // remote already destroyed the pane. Skip the echo.
        if suppressNextCloseFor.remove(herdrPaneId) != nil {
            return
        }

        // tmux detach semantics: local resources released, daemon
        // process preserved for the next reattach.
        if effectiveDetach {
            return
        }

        // Best-effort kill on the herdr side. tmux semantics: close
        // pane = kill the process. Routes through the transport
        // factory so SSH hosts get the same fire-and-forget treatment.
        Task.detached {
            await HerdrOneShotRPC.send(
                host: host,
                method: "pane.close",
                params: ["pane_id": herdrPaneId]
            )
        }
    }
}
