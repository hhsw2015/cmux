import Bonsplit
import Foundation

/// One herdr-backed subtree inside a cmux workspace. Records which
/// herdr workspace + tab is being mirrored, the host the daemon lives
/// on, and the pane id binding registry that maps cmux PaneIDs to
/// herdr pane ids inside this subtree.
///
/// `ownedCmuxPaneIds` reflects the current binding registry contents.
/// As bonsplit splits/swaps mutate the herdr-backed subtree, the
/// owning code (E2d) updates the binding registry; this set falls out
/// for free.
@MainActor
final class HerdrTabBinding {
    let host: HerdrHost
    let workspaceId: String
    let tabId: String
    /// The cmux pane that became slot 0 when the layout was first
    /// materialized. Useful as a stable handle even after the binding
    /// registry rotates pane ids around (e.g. swaps).
    let rootCmuxPaneId: UUID
    let paneBindings: HerdrPaneBindingRegistry
    /// Weak so a closed workspace doesn't keep the binding alive.
    /// E2e inbound LayoutChanged uses this to find the BonsplitController
    /// to mutate.
    weak var workspace: Workspace?
    /// Top-tabs PR #4829: the cmux layout tab this binding lives in.
    /// nil for legacy bindings registered before top tabs (single-layout
    /// world). Inbound LayoutChanged routes mutations to the
    /// BonsplitController for THIS layoutTab id, not the workspace's
    /// active tab — otherwise typing in a non-active tab would mutate
    /// the wrong tree.
    var cmuxLayoutTabId: UUID?

    init(
        host: HerdrHost,
        workspaceId: String,
        tabId: String,
        rootCmuxPaneId: UUID,
        paneBindings: HerdrPaneBindingRegistry,
        workspace: Workspace? = nil,
        cmuxLayoutTabId: UUID? = nil
    ) {
        self.host = host
        self.workspaceId = workspaceId
        self.tabId = tabId
        self.rootCmuxPaneId = rootCmuxPaneId
        self.paneBindings = paneBindings
        self.workspace = workspace
        self.cmuxLayoutTabId = cmuxLayoutTabId
    }

    /// Resolve the live BonsplitController this binding should mutate.
    /// Falls back to the workspace's active controller (legacy behavior)
    /// when cmuxLayoutTabId is nil — so existing register call sites
    /// that haven't been updated still work in single-layoutTab mode.
    var liveBonsplitController: BonsplitController? {
        guard let workspace else { return nil }
        if let layoutTabId = cmuxLayoutTabId,
           let controller = workspace.bonsplitController(forLayoutTabId: layoutTabId) {
            return controller
        }
        return workspace.bonsplitController(containingPaneId: PaneID(id: rootCmuxPaneId))
            ?? workspace.bonsplitController
    }

    var ownedCmuxPaneIds: Set<UUID> {
        Set(paneBindings.pairs.map { $0.cmux })
    }

    func owns(cmuxPaneId: UUID) -> Bool {
        paneBindings.herdrPaneId(forCmuxId: cmuxPaneId) != nil
    }
}

/// Process-wide registry of herdr-backed bonsplit subtrees. Used by
/// E2d mutation hooks to look up which herdr workspace+tab a cmux
/// operation belongs to so the matching RPC can be sent.
@MainActor
final class HerdrTabRegistry: ObservableObject {
    static let shared = HerdrTabRegistry()

    /// Posted when bindings change so UIs (sidebar) can re-evaluate
    /// "is this workspace currently attached" highlights without
    /// being directly observed.
    static let bindingsChangedNotification = Notification.Name(
        "cmux.herdr.tabRegistry.bindingsChanged"
    )

    private var bindings: [UUID: HerdrTabBinding] = [:]

    /// Register a freshly materialized herdr-backed subtree. `key` is
    /// any stable identifier the caller wants to use to retrieve or
    /// remove this binding later — typically the root cmux pane id.
    func register(key: UUID, binding: HerdrTabBinding) {
        bindings[key] = binding
        objectWillChange.send()
        NotificationCenter.default.post(
            name: Self.bindingsChangedNotification, object: nil
        )
    }

    func remove(key: UUID) {
        guard bindings.removeValue(forKey: key) != nil else { return }
        // Clear out per-binding state in HerdrInboundLayoutSync so a
        // future binding that happens to land on the same UUID
        // doesn't inherit a stale apply-throttle timestamp, a stale
        // pendingDividerSpec from the previous tree, or a stale
        // suppression entry. Caught by review #1 of bc76ffea.
        HerdrInboundLayoutSync.forgetBinding(rootCmuxPaneId: key)
        // Also drop the divider-sync's lastSeen so a future binding
        // doesn't diff against ratios from a tree that no longer
        // exists.
        HerdrDividerSync.reset(bindingKey: key)
        objectWillChange.send()
        NotificationCenter.default.post(
            name: Self.bindingsChangedNotification, object: nil
        )
    }

    /// Find the binding that owns a given cmux pane id, if any. O(N)
    /// in the number of registered bindings; expected to be small.
    func binding(forCmuxPaneId cmuxPaneId: UUID) -> HerdrTabBinding? {
        for binding in bindings.values where binding.owns(cmuxPaneId: cmuxPaneId) {
            return binding
        }
        return nil
    }

    func binding(forKey key: UUID) -> HerdrTabBinding? {
        bindings[key]
    }

    var allBindings: [HerdrTabBinding] {
        Array(bindings.values)
    }

    var count: Int {
        bindings.count
    }

    /// True when any binding's owning workspace matches `workspaceId`.
    /// Used by the sidebar tab item to render the persistent-workspace
    /// indicator (anchor icon) without subscribing to the registry's
    /// ObservableObject from inside the row, which would violate the
    /// snapshot-boundary perf rule on the workspace ForEach.
    func hasBinding(forWorkspaceId workspaceId: UUID) -> Bool {
        for binding in bindings.values where binding.workspace?.id == workspaceId {
            return true
        }
        return false
    }

    /// Returns the first binding whose owning cmux Workspace has the
    /// given id. Used by the bidirectional sync bridge to find the
    /// herdr handle for a cmux native rename / mutation.
    func firstBinding(forWorkspaceId workspaceId: UUID) -> HerdrTabBinding? {
        for binding in bindings.values where binding.workspace?.id == workspaceId {
            return binding
        }
        return nil
    }

    /// Reverse lookup: given a herdr workspace_id, find the cmux
    /// workspace UUID it's mirrored into. Drives the inbound apply
    /// path (daemon broadcast → update cmux side).
    func cmuxWorkspaceId(forHerdrWorkspace workspaceId: String, host: HerdrHost) -> UUID? {
        for binding in bindings.values
            where binding.workspaceId == workspaceId && binding.host.id == host.id {
            return binding.workspace?.id
        }
        return nil
    }
}
