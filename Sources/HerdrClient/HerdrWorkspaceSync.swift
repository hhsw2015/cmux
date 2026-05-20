import Foundation

/// Bidirectional state sync between cmux's native workspace model
/// (TabManager.tabs[].customTitle / customDescription) and herdr's
/// workspace label/description. Without this bridge, a user editing
/// a workspace name in cmux's main sidebar would have the change
/// silently overwritten the next time cmux pulled `workspace.list`
/// from the daemon, because the daemon never learned about the rename.
///
/// Re-entrance defense: every label/description value cmux sends or
/// receives is stamped into a per-binding cache. Outbound is skipped
/// when the new value equals the cached one (we just observed it
/// inbound), and inbound is skipped when the value matches what we
/// last sent. Stops the daemon-broadcast → cmux apply → cmux setter
/// → outbound RPC loop dead in two hops.
@MainActor
final class HerdrWorkspaceSync {
    static let shared = HerdrWorkspaceSync()

    private struct Key: Hashable {
        let hostId: UUID
        let workspaceId: String
    }

    private struct LastKnown {
        var label: String?
        var description: String?
    }

    private var cache: [Key: LastKnown] = [:]

    private init() {}

    // MARK: - Outbound (cmux user action -> herdr daemon)

    /// Called by TabManager.setCustomTitle. No-op if the cmux tab isn't
    /// herdr-backed (purely local workspace) or if the new value
    /// matches what we last received from the daemon.
    func reportLocalRename(cmuxWorkspaceId: UUID, newTitle: String?) {
        guard let binding = HerdrTabRegistry.shared.firstBinding(forWorkspaceId: cmuxWorkspaceId) else {
            return
        }
        let key = Key(hostId: binding.host.id, workspaceId: binding.workspaceId)
        let label = newTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if cache[key]?.label == label { return }
        var entry = cache[key] ?? LastKnown()
        entry.label = label
        cache[key] = entry
        Task.detached { [host = binding.host, wsId = binding.workspaceId] in
            await HerdrOneShotRPC.send(
                host: host,
                method: "workspace.rename",
                params: ["workspace_id": wsId, "label": label]
            )
        }
    }

    /// Called by TabManager.setCustomDescription. The herdr API name
    /// is workspace.set_description; the daemon stores it as a
    /// free-form note attached to the workspace entry.
    func reportLocalDescription(cmuxWorkspaceId: UUID, newDescription: String?) {
        guard let binding = HerdrTabRegistry.shared.firstBinding(forWorkspaceId: cmuxWorkspaceId) else {
            return
        }
        let key = Key(hostId: binding.host.id, workspaceId: binding.workspaceId)
        let desc = newDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if cache[key]?.description == desc { return }
        var entry = cache[key] ?? LastKnown()
        entry.description = desc
        cache[key] = entry
        Task.detached { [host = binding.host, wsId = binding.workspaceId] in
            await HerdrOneShotRPC.send(
                host: host,
                method: "workspace.set_description",
                params: ["workspace_id": wsId, "description": desc]
            )
        }
    }

    // MARK: - Inbound (herdr daemon -> cmux state)

    /// Called by HerdrWorkspaceListStore after a successful
    /// workspace.list refresh, for every workspace the daemon
    /// reports. Updates cmux's tab.customTitle / customDescription
    /// when the daemon's value differs from cmux's local value AND
    /// from what we last echoed outbound (re-entrance guard).
    func applyRemoteWorkspace(host: HerdrHost, workspaceId: String, label: String, description: String?) {
        let key = Key(hostId: host.id, workspaceId: workspaceId)
        let isFirstSync = cache[key] == nil
        var entry = cache[key] ?? LastKnown()
        var labelChanged = false
        var descChanged = false
        if entry.label != label {
            entry.label = label
            labelChanged = true
        }
        if let description, entry.description != description {
            entry.description = description
            descChanged = true
        }
        if labelChanged || descChanged {
            cache[key] = entry
        } else {
            return
        }
        guard let cmuxId = HerdrTabRegistry.shared.cmuxWorkspaceId(
            forHerdrWorkspace: workspaceId, host: host
        ) else { return }
        guard let manager = AppDelegate.shared?.tabManagerFor(tabId: cmuxId) else { return }

        // First-sync rule: cmux is authoritative for a freshly-bound
        // workspace. If cmux already has a name/description set on the
        // tab (or it just got created with a server-default label we
        // don't want stamped onto the local customTitle), push cmux's
        // value to the daemon instead of letting the daemon's default
        // overwrite the local one. Without this guard, the very first
        // workspace.list refresh after binding silently renames the
        // user's existing tab to the daemon's `cmux-workspace`.
        if isFirstSync {
            if let cmuxTab = manager.tabs.first(where: { $0.id == cmuxId }) {
                if let localTitle = cmuxTab.customTitle, !localTitle.isEmpty, localTitle != label {
                    entry.label = localTitle
                    cache[key] = entry
                    Task.detached { [host] in
                        await HerdrOneShotRPC.send(
                            host: host,
                            method: "workspace.rename",
                            params: ["workspace_id": workspaceId, "label": localTitle]
                        )
                    }
                    labelChanged = false
                }
                if let localDesc = cmuxTab.customDescription,
                   !localDesc.isEmpty,
                   localDesc != description {
                    entry.description = localDesc
                    cache[key] = entry
                    Task.detached { [host] in
                        await HerdrOneShotRPC.send(
                            host: host,
                            method: "workspace.set_description",
                            params: ["workspace_id": workspaceId, "description": localDesc]
                        )
                    }
                    descChanged = false
                }
            }
        }

        if labelChanged {
            // Empty label means the user cleared it on the other side
            // — clear our customTitle too so we fall back to
            // auto-generated title rather than display "".
            let next: String? = label.isEmpty ? nil : label
            manager.setCustomTitle(tabId: cmuxId, title: next, source: .herdrInbound)
        }
        if descChanged {
            let next: String? = (description?.isEmpty ?? true) ? nil : description
            manager.setCustomDescription(tabId: cmuxId, description: next, source: .herdrInbound)
        }
    }

    /// Drop cached state when a workspace is deleted so a future
    /// workspace_id reuse doesn't inherit stale values.
    func forget(host: HerdrHost, workspaceId: String) {
        cache.removeValue(forKey: Key(hostId: host.id, workspaceId: workspaceId))
    }
}

/// Origin marker used by TabManager mutators to suppress the outbound
/// echo when the change came in from the daemon. Without this enum
/// hint, every inbound rename would loop back out as an outbound RPC
/// that the daemon would re-broadcast.
enum WorkspaceMutationSource {
    case userInput
    case herdrInbound
}
