import Bonsplit
import Foundation

/// Applies a remote `layout.changed` event to cmux's bonsplit tree.
/// Mirror image of `HerdrDividerSync` (which sends outbound). Together
/// they let two cmux clients (or cmux + herdr's TUI) stay in sync on
/// divider positions and structural mutations.
///
/// Scope today: divider ratios, removals, and additions (single or
/// multi). Adds run in a fixed-point loop so a new pane whose sibling
/// is itself a new pane gets processed once that sibling is bound.
/// Swaps that don't preserve the leaf set still bail with a debug log;
/// the user can re-open the workspace to resync.
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

        let spec = HerdrLayoutSpec(from: tree)
        let newPaneIds = Set(spec.root.allHerdrPaneIds)
        let oldPaneIds = Set(binding.paneBindings.pairs.map { $0.herdr })

        if newPaneIds == oldPaneIds {
            applyDividers(spec: spec, binding: binding, workspace: workspace)
            return
        }

        let added = newPaneIds.subtracting(oldPaneIds)
        let removed = oldPaneIds.subtracting(newPaneIds)

        // Removals are order-independent — each cmux pane closes
        // standalone — so process the whole set up front so subsequent
        // additions see the post-remove tree.
        for herdrId in removed {
            applyRemoval(herdrPaneId: herdrId, binding: binding, workspace: workspace)
        }

        if added.isEmpty {
            applyDividers(spec: spec, binding: binding, workspace: workspace)
            return
        }

        Task { @MainActor in
            await applyAdditions(
                added: added,
                spec: spec,
                binding: binding,
                workspace: workspace
            )
            applyDividers(spec: spec, binding: binding, workspace: workspace)
        }
    }

    /// Process every added pane. Adds run iteratively: in each pass
    /// we pick a pane whose sibling is already bound (existing or
    /// just-added), apply it, and restart. This handles the case
    /// where two adds in the same event are siblings of each other
    /// (one split, then a split of the new pane) by fixing their
    /// processing order via the sibling-binding precondition.
    private static func applyAdditions(
        added: Set<String>,
        spec: HerdrLayoutSpec,
        binding: HerdrTabBinding,
        workspace: Workspace
    ) async {
        var pending = added
        while !pending.isEmpty {
            guard let resolved = nextResolvableAddition(
                pending: pending,
                spec: spec,
                isBound: { binding.paneBindings.cmuxPaneId(forHerdrId: $0) != nil }
            ) else {
                cmuxDebugLog(
                    "herdr.inbound: stalled multi-add (\(pending.count) unresolved); workspace may be out of sync"
                )
                return
            }
            await applyAddition(
                addedHerdrId: resolved,
                spec: spec,
                binding: binding,
                workspace: workspace
            )
            pending.remove(resolved)
        }
    }

    /// Pure order-resolution helper for `applyAdditions`. Picks any
    /// pending added pane whose sibling in the spec tree is already
    /// bound (existing or just-added). Returns nil if no pane in
    /// `pending` qualifies — caller treats that as a stall.
    static func nextResolvableAddition(
        pending: Set<String>,
        spec: HerdrLayoutSpec,
        isBound: (String) -> Bool
    ) -> String? {
        for herdrId in pending {
            guard let parent = findParentSplit(node: spec.root, target: herdrId) else {
                continue
            }
            if isBound(parent.siblingHerdrId) {
                return herdrId
            }
        }
        return nil
    }

    /// Remote `workspace.closed` event: kill every cmux pane the
    /// matching binding owns. Each close goes through the
    /// `suppressNextCloseFor` echo guard so we don't bounce
    /// `pane.close` back at the daemon for panes that are already
    /// gone server-side.
    static func applyWorkspaceClosed(workspaceId: String) {
        let bindings = HerdrTabRegistry.shared.allBindings.filter { $0.workspaceId == workspaceId }
        for binding in bindings {
            guard let workspace = binding.workspace else { continue }
            let pairs = binding.paneBindings.pairs
            for (cmuxPaneId, herdrPaneId) in pairs {
                HerdrCloseHandler.suppressNextCloseFor.insert(herdrPaneId)
                workspace.bonsplitController.closePane(PaneID(id: cmuxPaneId))
            }
            cmuxDebugLog(
                "herdr.inbound: workspace \(workspaceId) closed remotely; tore down \(pairs.count) pane(s)"
            )
        }
    }

    // MARK: - Divider ratio sync

    private static func applyDividers(
        spec: HerdrLayoutSpec,
        binding: HerdrTabBinding,
        workspace: Workspace
    ) {
        let cmuxTree = workspace.bonsplitController.treeSnapshot()
        guard let cmuxSubtree = findCmuxSubtreeRoot(tree: cmuxTree, binding: binding) else {
            return
        }
        let newDividers = collectDividers(spec.root, prefix: [])
        for (path, ratio) in newDividers {
            guard let splitId = findSplitId(in: cmuxSubtree, atPath: path) else { continue }
            workspace.bonsplitController.setDividerPosition(
                CGFloat(ratio),
                forSplit: splitId,
                fromExternal: true
            )
        }
        HerdrDividerSync.setLastSeen(bindingKey: binding.rootCmuxPaneId, value: newDividers)
    }

    // MARK: - Structural: removal

    private static func applyRemoval(
        herdrPaneId: String,
        binding: HerdrTabBinding,
        workspace: Workspace
    ) {
        guard let cmuxPaneId = binding.paneBindings.cmuxPaneId(forHerdrId: herdrPaneId) else {
            return
        }
        // Suppress the outbound pane.close echo — remote already closed.
        HerdrCloseHandler.suppressNextCloseFor.insert(herdrPaneId)
        workspace.bonsplitController.closePane(PaneID(id: cmuxPaneId))
        // didClosePane → HerdrCloseHandler.handlePanelClosed runs the
        // local cleanup (HerdrPanelRegistry.remove, binding unbind).
        cmuxDebugLog("herdr.inbound: removed pane \(herdrPaneId)")
    }

    // MARK: - Structural: addition

    private static func applyAddition(
        addedHerdrId: String,
        spec: HerdrLayoutSpec,
        binding: HerdrTabBinding,
        workspace: Workspace
    ) async {
        guard let parent = findParentSplit(node: spec.root, target: addedHerdrId) else {
            cmuxDebugLog("herdr.inbound: added pane \(addedHerdrId) has no parent split")
            return
        }
        guard let cmuxSiblingId = binding.paneBindings.cmuxPaneId(forHerdrId: parent.siblingHerdrId) else {
            cmuxDebugLog(
                "herdr.inbound: sibling \(parent.siblingHerdrId) of added \(addedHerdrId) has no cmux pane"
            )
            return
        }

        let host = binding.host
        guard let exec = HerdrLocalBinary.resolve() else {
            cmuxDebugLog("herdr.inbound: addition skipped — no local binary")
            return
        }
        let socketPath = host.localApiSocketPath

        let api = HerdrApiClient(transport: LocalUDSTransport(socketPath: socketPath))
        do {
            try await api.start()
            defer { Task { await api.close() } }
            let resp = try await api.request(
                method: "pane.get",
                params: ["pane_id": addedHerdrId]
            )
            guard let paneInfo = resp["pane"] as? [String: Any],
                  let terminalId = paneInfo["terminal_id"] as? String
            else {
                cmuxDebugLog("herdr.inbound: pane.get returned no terminal_id for \(addedHerdrId)")
                return
            }

            guard let newCmuxPaneId = workspace.herdrInboundSplit(
                paneId: PaneID(id: cmuxSiblingId),
                orientation: parent.orientation,
                initialDividerPosition: CGFloat(parent.ratio)
            ) else {
                cmuxDebugLog("herdr.inbound: bonsplit splitPane returned nil for sibling \(cmuxSiblingId)")
                return
            }

            binding.paneBindings.bind(cmuxPaneId: newCmuxPaneId.id, herdrPaneId: addedHerdrId)

            _ = try await HerdrPanelOpener.wireHerdrBackedPanel(
                workspace: workspace,
                cmuxPaneId: newCmuxPaneId,
                host: host,
                terminalId: terminalId,
                herdrPaneId: addedHerdrId,
                executablePath: exec,
                socketPath: socketPath,
                focus: false
            )

            // Re-prime divider lastSeen so the geometry change from
            // this materialization doesn't echo back as a user drag.
            HerdrDividerSync.prime(
                binding: binding,
                treeSnapshot: workspace.bonsplitController.treeSnapshot()
            )
            cmuxDebugLog("herdr.inbound: added pane \(addedHerdrId)")
        } catch {
            cmuxDebugLog("herdr.inbound: addition failed for \(addedHerdrId): \(error)")
        }
    }

    // MARK: - Tree walks

    /// Internal (not private) so HerdrInboundLayoutSyncTests can
    /// exercise the pure tree-walk logic without spinning up a
    /// workspace. Same for findParentSplit / findSplitId /
    /// collectDividers below.
    struct ParentSplit: Equatable {
        let orientation: SplitOrientation
        let ratio: CGFloat
        let siblingHerdrId: String
    }

    /// Find the immediate-parent split of a leaf `target` in the spec.
    /// Returns parent's orientation/ratio plus the target's sibling
    /// herdr id (which must be a leaf — herdr's pane.split always
    /// targets a leaf, so this holds for events generated by it).
    static func findParentSplit(
        node: HerdrLayoutSpecNode,
        target: String
    ) -> ParentSplit? {
        switch node {
        case .pane:
            return nil
        case .split(let orientation, let ratio, let first, let second):
            if case .pane(let id) = first, id == target {
                if case .pane(let siblingId) = second {
                    return ParentSplit(
                        orientation: orientation,
                        ratio: CGFloat(ratio),
                        siblingHerdrId: siblingId
                    )
                }
            }
            if case .pane(let id) = second, id == target {
                if case .pane(let siblingId) = first {
                    return ParentSplit(
                        orientation: orientation,
                        ratio: CGFloat(ratio),
                        siblingHerdrId: siblingId
                    )
                }
            }
            if let inner = findParentSplit(node: first, target: target) {
                return inner
            }
            return findParentSplit(node: second, target: target)
        }
    }

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

    static func findSplitId(
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

    static func collectDividers(
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
