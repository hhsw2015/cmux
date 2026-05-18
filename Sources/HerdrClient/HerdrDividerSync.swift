#if DEBUG
import Bonsplit
import Foundation

/// Outbound divider-drag sync: when bonsplit reports a geometry
/// change, find any herdr-backed subtrees, diff their split ratios
/// against the last-seen state, and fire one-shot `pane.set_split_ratio`
/// RPCs for every changed divider.
///
/// `shouldNotifyDuringDrag` defaults to false in cmux's bonsplit
/// delegate, so this fires once per drag-end rather than per pixel —
/// no debouncing needed.
@MainActor
enum HerdrDividerSync {
    /// Last-seen divider state per binding key (rootCmuxPaneId).
    /// Key: binding.rootCmuxPaneId. Value: path → ratio.
    private static var lastSeen: [UUID: [[Bool]: Float]] = [:]

    /// Two ratios closer than this are treated as identical. Bonsplit
    /// stores divider positions as `CGFloat` and herdr's ratatui
    /// quantizes them to integer columns/rows; round-trip drift is
    /// far below 1e-3 so this avoids spurious sync RPCs while still
    /// catching real user drags.
    private static let ratioEpsilon: Float = 1e-3

    /// Walk the workspace's bonsplit tree, find each herdr-backed
    /// subtree, and emit `pane.set_split_ratio` RPCs for every divider
    /// whose ratio changed since the previous call.
    static func sync(treeSnapshot: ExternalTreeNode) {
        for binding in HerdrTabRegistry.shared.allBindings {
            guard let subtree = findHerdrSubtreeRoot(tree: treeSnapshot, binding: binding) else {
                // The bonsplit tree no longer contains exactly this
                // binding's panes (panes were closed, swapped, or
                // mixed with non-herdr siblings). Skip until the
                // shape stabilizes; E2d-close handles pruning.
                continue
            }
            let current = collectDividers(tree: subtree, prefix: [])
            let previous = lastSeen[binding.rootCmuxPaneId] ?? [:]
            for (path, ratio) in current where !ratiosEqual(previous[path], ratio) {
                let host = binding.host
                let workspaceId = binding.workspaceId
                let tabId = binding.tabId
                Task.detached {
                    await HerdrOneShotRPC.send(
                        host: host,
                        method: "pane.set_split_ratio",
                        params: [
                            "workspace_id": workspaceId,
                            "tab_id": tabId,
                            "path": path,
                            "ratio": Double(ratio),
                        ]
                    )
                }
            }
            lastSeen[binding.rootCmuxPaneId] = current
        }
    }

    /// Reset bookkeeping for a binding (called when E2d-close drops
    /// the last pane and removes the binding).
    static func reset(bindingKey: UUID) {
        lastSeen.removeValue(forKey: bindingKey)
    }

    /// Seed `lastSeen` for a freshly materialized binding so the first
    /// `didChangeGeometry` after open doesn't fire pane.set_split_ratio
    /// RPCs for ratios herdr already knows about. Uses the binding's
    /// own pane set + the current bonsplit tree.
    static func prime(binding: HerdrTabBinding, treeSnapshot: ExternalTreeNode) {
        guard let subtree = findHerdrSubtreeRoot(tree: treeSnapshot, binding: binding) else {
            return
        }
        lastSeen[binding.rootCmuxPaneId] = collectDividers(tree: subtree, prefix: [])
    }

    /// Overwrite lastSeen with values inferred from a remote
    /// LayoutChanged event. Called by `HerdrInboundLayoutSync` after
    /// applying a remote tree to bonsplit so the local
    /// `didChangeGeometry` echo doesn't fire pane.set_split_ratio
    /// back at the daemon (combined with bonsplit's
    /// `isExternalUpdateInProgress` 50ms guard).
    static func setLastSeen(bindingKey: UUID, value: [[Bool]: Float]) {
        lastSeen[bindingKey] = value
    }

    private static func ratiosEqual(_ lhs: Float?, _ rhs: Float) -> Bool {
        guard let lhs else { return false }
        return abs(lhs - rhs) < ratioEpsilon
    }

    // MARK: - Tree walk helpers

    /// Find the smallest subtree of `tree` whose leaves exactly equal
    /// the cmux pane ids in `binding`. Returns nil if no such subtree
    /// exists (shape doesn't match — split, swap, or other mutation
    /// in flight).
    private static func findHerdrSubtreeRoot(
        tree: ExternalTreeNode,
        binding: HerdrTabBinding
    ) -> ExternalTreeNode? {
        let leafIds = collectLeafCmuxIds(tree: tree)
        if leafIds == binding.ownedCmuxPaneIds && !leafIds.isEmpty {
            return tree
        }
        guard case .split(let split) = tree else {
            return nil
        }
        return findHerdrSubtreeRoot(tree: split.first, binding: binding)
            ?? findHerdrSubtreeRoot(tree: split.second, binding: binding)
    }

    private static func collectLeafCmuxIds(tree: ExternalTreeNode) -> Set<UUID> {
        switch tree {
        case .pane(let pane):
            guard let uuid = UUID(uuidString: pane.id) else { return [] }
            return [uuid]
        case .split(let split):
            return collectLeafCmuxIds(tree: split.first)
                .union(collectLeafCmuxIds(tree: split.second))
        }
    }

    private static func collectDividers(
        tree: ExternalTreeNode,
        prefix: [Bool]
    ) -> [[Bool]: Float] {
        switch tree {
        case .pane:
            return [:]
        case .split(let split):
            var result: [[Bool]: Float] = [prefix: Float(split.dividerPosition)]
            for (childPath, childRatio) in collectDividers(tree: split.first, prefix: prefix + [false]) {
                result[childPath] = childRatio
            }
            for (childPath, childRatio) in collectDividers(tree: split.second, prefix: prefix + [true]) {
                result[childPath] = childRatio
            }
            return result
        }
    }

}
#endif
