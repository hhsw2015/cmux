#if DEBUG
import Bonsplit
import Foundation

/// Applies a remote `layout.changed` event to cmux's bonsplit tree.
/// Mirror image of `HerdrDividerSync` (which sends outbound). Together
/// they let two cmux clients (or cmux + herdr's TUI) stay in sync on
/// divider positions and structural mutations.
///
/// Scope today: divider ratios + single-pane structural changes
/// (one add or one remove per event). Larger structural changes
/// (multi-pane adds/removes in a single event, swaps that don't
/// preserve the leaf set) bail with a debug log; the user can re-open
/// the workspace to resync.
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

        if added.count + removed.count > 1 {
            cmuxDebugLog(
                "herdr.inbound: multi-change ignored (added=\(added.count) removed=\(removed.count))"
            )
            return
        }

        if let removedHerdrId = removed.first {
            applyRemoval(herdrPaneId: removedHerdrId, binding: binding, workspace: workspace)
            // Ratios may shift after the close (sibling absorbs the
            // freed space). Re-apply once the structural change settles.
            applyDividers(spec: spec, binding: binding, workspace: workspace)
            return
        }

        if let addedHerdrId = added.first {
            Task { @MainActor in
                await applyAddition(
                    addedHerdrId: addedHerdrId,
                    spec: spec,
                    binding: binding,
                    workspace: workspace
                )
            }
        }
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
        let exec = (("~/.local/bin/herdr-cmux") as NSString).expandingTildeInPath
        let socketPath = (("~/.config/herdr/sessions/" + host.sessionName + "/herdr.sock") as NSString)
            .expandingTildeInPath

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

    private struct ParentSplit {
        let orientation: SplitOrientation
        let ratio: CGFloat
        let siblingHerdrId: String
    }

    /// Find the immediate-parent split of a leaf `target` in the spec.
    /// Returns parent's orientation/ratio plus the target's sibling
    /// herdr id (which must be a leaf — herdr's pane.split always
    /// targets a leaf, so this holds for events generated by it).
    private static func findParentSplit(
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
