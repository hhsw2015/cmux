#if DEBUG
import Bonsplit
import Foundation

/// Applies a remote `layout.changed` event to cmux's bonsplit tree.
/// Mirror image of `HerdrDividerSync` (which sends outbound). Together
/// they let two cmux clients (or cmux + herdr's TUI) stay in sync on
/// divider positions.
///
/// MVP scope: divider ratio sync only. Structural changes (pane added
/// or removed by another client) trigger a "subtree shape mismatch"
/// path that's a no-op until E2e-2 lands proper structural reconcile.
@MainActor
enum HerdrInboundLayoutSync {
    static func apply(tree: HerdrLayoutTree) {
        guard let binding = HerdrTabRegistry.shared.allBindings.first(where: {
            $0.workspaceId == tree.workspaceId && $0.tabId == tree.tabId
        }) else {
            return
        }
        guard let workspace = binding.workspace else {
            return
        }

        let cmuxTree = workspace.bonsplitController.treeSnapshot()
        guard let cmuxSubtree = findCmuxSubtreeRoot(tree: cmuxTree, binding: binding) else {
            // Shape mismatch — likely a remote split or close in flight.
            // E2e-2 will handle structural reconcile; for now skip.
            return
        }

        let spec = HerdrLayoutSpec(from: tree)
        let newDividers = collectDividers(spec.root, prefix: [])

        for (path, ratio) in newDividers {
            guard let splitId = findSplitId(in: cmuxSubtree, atPath: path) else { continue }
            workspace.bonsplitController.setDividerPosition(
                CGFloat(ratio),
                forSplit: splitId,
                fromExternal: true
            )
        }

        // Update outbound lastSeen so the geometry echo from
        // setDividerPosition (within bonsplit's 50ms external-update
        // window) doesn't push pane.set_split_ratio back at the daemon.
        HerdrDividerSync.setLastSeen(bindingKey: binding.rootCmuxPaneId, value: newDividers)
    }

    // MARK: - Tree walks

    private static func findCmuxSubtreeRoot(
        tree: ExternalTreeNode,
        binding: HerdrTabBinding
    ) -> ExternalTreeNode? {
        let leaves = collectLeafCmuxIds(tree: tree)
        if leaves == binding.ownedCmuxPaneIds && !leaves.isEmpty {
            return tree
        }
        guard case .split(let split) = tree else { return nil }
        return findCmuxSubtreeRoot(tree: split.first, binding: binding)
            ?? findCmuxSubtreeRoot(tree: split.second, binding: binding)
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

    private static func findSplitId(
        in tree: ExternalTreeNode,
        atPath path: [Bool]
    ) -> UUID? {
        if path.isEmpty {
            guard case .split(let split) = tree else { return nil }
            return UUID(uuidString: split.id)
        }
        guard case .split(let split) = tree else { return nil }
        let next = path[0] ? split.second : split.first
        return findSplitId(in: next, atPath: Array(path.dropFirst()))
    }

    private static func collectDividers(
        _ node: HerdrLayoutSpecNode,
        prefix: [Bool]
    ) -> [[Bool]: Float] {
        switch node {
        case .pane:
            return [:]
        case .split(_, let ratio, let first, let second):
            var result: [[Bool]: Float] = [prefix: Float(ratio)]
            for (childPath, childRatio) in collectDividers(first, prefix: prefix + [false]) {
                result[childPath] = childRatio
            }
            for (childPath, childRatio) in collectDividers(second, prefix: prefix + [true]) {
                result[childPath] = childRatio
            }
            return result
        }
    }
}
#endif
