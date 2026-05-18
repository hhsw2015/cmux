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

    init(
        host: HerdrHost,
        workspaceId: String,
        tabId: String,
        rootCmuxPaneId: UUID,
        paneBindings: HerdrPaneBindingRegistry,
        workspace: Workspace? = nil
    ) {
        self.host = host
        self.workspaceId = workspaceId
        self.tabId = tabId
        self.rootCmuxPaneId = rootCmuxPaneId
        self.paneBindings = paneBindings
        self.workspace = workspace
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
final class HerdrTabRegistry {
    static let shared = HerdrTabRegistry()

    private var bindings: [UUID: HerdrTabBinding] = [:]

    /// Register a freshly materialized herdr-backed subtree. `key` is
    /// any stable identifier the caller wants to use to retrieve or
    /// remove this binding later — typically the root cmux pane id.
    func register(key: UUID, binding: HerdrTabBinding) {
        bindings[key] = binding
    }

    func remove(key: UUID) {
        bindings.removeValue(forKey: key)
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
}
