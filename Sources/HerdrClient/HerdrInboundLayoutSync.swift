import Bonsplit
import Foundation
import os.log

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
    /// Pending ratio-only specs awaiting coalesced apply (keyed by
    /// binding root id). TUI mouse drag fires LayoutChanged at 60 Hz
    /// during a divider drag; applying each one synchronously sends
    /// 60 PTY resize signals per second, which the user observes as
    /// choppy redraws and momentary blank cells around the cursor.
    /// Coalesce ratio-only events to one apply per runloop turn.
    private static var pendingDividerSpec: [UUID: HerdrLayoutSpec] = [:]
    private static var dividerApplyScheduled: Set<UUID> = []

    /// Last time we ran applyDividers for a binding. The coalescer
    /// already drops to one apply per runloop turn, but a remote TUI
    /// drag delivers LayoutChanged at 60Hz over the events stream,
    /// and bonsplit's setDividerPosition + the surface-frame /
    /// geometry-reconcile fan-out it triggers is not free even when
    /// repeated 60 times per second. Runloop-rate apply is fine on a
    /// local UDS daemon; over SSH the same workload appears to
    /// starve the raw-pty-attach channel sharing the master, and the
    /// user sees the panel "freeze" mid-drag. Cap to 30Hz; the
    /// pendingDividerSpec map already retains the latest tree so
    /// the eventual settled apply still uses the final ratios.
    private static var lastDividerApplyAt: [UUID: Date] = [:]
    static let dividerApplyMinInterval: TimeInterval = 0.033

    /// While true, outbound pane.resize is suppressed because the
    /// resize was caused by us mirroring the daemon's own layout. The
    /// daemon already knows what size the PTY should be (it's the
    /// origin of the layout_changed event), so echoing pane.resize
    /// back during inbound apply is pure SSH chatter that competes
    /// for the master's bandwidth with the raw-pty-attach output we
    /// actually want to land on screen.
    private static var inboundApplyActiveCount: Int = 0
    private static var inboundApplySuppressUntil: Date = .distantPast
    static let inboundApplySuppressTrailingMs: Int = 250

    /// Tested by HerdrPanelOpener.forwardPanelSize before queuing the
    /// outbound RPC.
    static var shouldSuppressOutboundResize: Bool {
        inboundApplyActiveCount > 0 || Date() < inboundApplySuppressUntil
    }

    /// Test seam. Pretends an inbound apply is running for `block`'s
    /// duration so HerdrInboundLayoutSyncTests can assert that
    /// shouldSuppressOutboundResize flips correctly without having to
    /// stand up a full Workspace + bonsplit harness.
    static func _withInboundApplyActiveForTesting<T>(_ block: () -> T) -> T {
        inboundApplyActiveCount += 1
        defer {
            inboundApplyActiveCount -= 1
            inboundApplySuppressUntil = Date().addingTimeInterval(
                Double(inboundApplySuppressTrailingMs) / 1000.0
            )
        }
        return block()
    }

    /// Test seam. Resets the suppression-window state so tests don't
    /// leak across cases.
    static func _resetSuppressionForTesting() {
        inboundApplyActiveCount = 0
        inboundApplySuppressUntil = .distantPast
        lastDividerApplyAt.removeAll()
    }

    static func apply(tree: HerdrLayoutTree) {
        let allBindings = HerdrTabRegistry.shared.allBindings
        guard let binding = allBindings.first(where: {
            $0.workspaceId == tree.workspaceId && $0.tabId == tree.tabId
        }) else {
            os_log(
                "herdr.inbound.apply no_binding ws=%{public}@ tab=%{public}@ bindings=%{public}d",
                tree.workspaceId, tree.tabId, allBindings.count
            )
            return
        }
        guard let workspace = binding.workspace else {
            os_log(
                "herdr.inbound.apply no_workspace ws=%{public}@ tab=%{public}@",
                tree.workspaceId, tree.tabId
            )
            return
        }

        let spec = HerdrLayoutSpec(from: tree)
        let newPaneIds = Set(spec.root.allHerdrPaneIds)
        let oldPaneIds = Set(binding.paneBindings.pairs.map { $0.herdr })

        if newPaneIds == oldPaneIds {
            scheduleDividerApply(spec: spec, binding: binding, workspace: workspace)
            return
        }
        os_log(
            "herdr.inbound.apply structural ws=%{public}@ tab=%{public}@ new=%{public}d old=%{public}d",
            tree.workspaceId, tree.tabId, newPaneIds.count, oldPaneIds.count
        )

        let added = newPaneIds.subtracting(oldPaneIds)
        let removed = oldPaneIds.subtracting(newPaneIds)

        // Drop any in-flight divider coalescer for this binding —
        // a structural change supersedes ratio-only updates and
        // applying a stale divider spec on top of the new tree
        // could resize panes that no longer exist or skip the
        // ratios for newly added panes.
        let key = binding.rootCmuxPaneId
        pendingDividerSpec.removeValue(forKey: key)
        dividerApplyScheduled.remove(key)

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
                os_log(
                    "herdr.inbound.applyAdditions stalled unresolved=%{public}d",
                    pending.count
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

    /// Remote `pane.zoomed` event: mirror the daemon's zoom state on
    /// the matching cmux Workspace. tmux/herdr semantics: only one
    /// pane per tab is zoomed at a time, so applying this is either
    /// "zoom this pane" or "clear zoom". Idempotent: if bonsplit
    /// already matches, no-op — that's the echo-suppression mechanism
    /// for cmux→daemon→cmux round-trips. (No explicit lastSent cache:
    /// it absorbed corrective broadcasts when the user rapid-toggled
    /// and left cmux desynced from the daemon.)
    static func applyZoom(
        host: HerdrHost,
        workspaceId: String,
        tabId: String,
        herdrPaneId: String,
        zoomed: Bool
    ) {
        guard let binding = HerdrTabRegistry.shared.allBindings.first(where: {
            $0.host.id == host.id
                && $0.workspaceId == workspaceId
                && $0.tabId == tabId
        }) else { return }
        guard let workspace = binding.workspace else { return }
        let controller = workspace.bonsplitController
        if !zoomed {
            if controller.zoomedPaneId == nil { return }
            controller.clearPaneZoom()
            return
        }
        guard let cmuxPaneId = binding.paneBindings.cmuxPaneId(forHerdrId: herdrPaneId) else {
            return
        }
        let target = PaneID(id: cmuxPaneId)
        if controller.zoomedPaneId == target { return }
        controller.togglePaneZoom(inPane: target)
    }

    /// Remote `tab.closed` event: kill every cmux pane the binding
    /// for (host, tabId) owns. Same echo-guard pattern as
    /// `applyWorkspaceClosed`.
    static func applyTabClosed(host: HerdrHost, tabId: String) {
        let bindings = HerdrTabRegistry.shared.allBindings.filter {
            $0.host.id == host.id && $0.tabId == tabId
        }
        for binding in bindings {
            tearDownEntireBinding(binding: binding, reason: "tab \(tabId) closed remotely")
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
            tearDownEntireBinding(binding: binding, reason: "workspace \(workspaceId) closed remotely")
        }
    }

    /// Shared teardown for tab/workspace/host close: close every
    /// bound cmux pane in the workspace, then close the workspace
    /// itself. bonsplit refuses to close the last pane (allowCloseLastPane
    /// is false), so iterating panes leaves a stranded final pane
    /// with a dead PTY — the user sees a stuck unresponsive panel.
    /// Closing the workspace at the end via TabManager handles that
    /// case cleanly: the workspace disappears from the sidebar and
    /// the remaining bonsplit pane goes with it.
    private static func tearDownEntireBinding(binding: HerdrTabBinding, reason: String) {
        guard let workspace = binding.workspace else { return }
        let pairs = binding.paneBindings.pairs
        // Pre-mark every herdr pane id so each closePane echo back to
        // HerdrCloseHandler is suppressed (daemon already destroyed
        // the panes).
        for (_, herdrPaneId) in pairs {
            HerdrCloseHandler.suppressNextCloseFor.insert(herdrPaneId)
        }
        // Force-close every bonsplit pane the binding owned. The last
        // closePane will be refused by bonsplit's "don't close the
        // last pane" guard; we handle that by closing the workspace
        // outright below.
        workspace.markAllTabsForceCloseable()
        for (cmuxPaneId, _) in pairs {
            workspace.bonsplitController.closePane(PaneID(id: cmuxPaneId))
        }
        os_log(
            "herdr.inbound.teardown reason=%{public}@ panes=%{public}d",
            reason, pairs.count
        )
        // Close the workspace via TabManager so the surviving last
        // pane (bonsplit kept one alive) doesn't sit unresponsive.
        // Detach semantics — preserve persistence in case the user
        // restarts the daemon and wants reattach to recreate it.
        guard let tabManager = AppDelegate.shared?.tabManager else { return }
        let cmuxWorkspaceId = workspace.id
        guard tabManager.tabs.contains(where: { $0.id == cmuxWorkspaceId }) else { return }
        HerdrCloseHandler.detachingWorkspaceIds.insert(cmuxWorkspaceId)
        defer { HerdrCloseHandler.detachingWorkspaceIds.remove(cmuxWorkspaceId) }
        tabManager.closeWorkspace(workspace, recordHistory: false)
    }

    // MARK: - Divider ratio sync

    /// Coalesce ratio-only LayoutChanged events: stash latest spec
    /// and run a single applyDividers per runloop turn. Drops stale
    /// intermediate frames so 60 Hz drag traffic resolves to one
    /// apply per macOS frame, which is what NSSplitView consumes.
    private static func scheduleDividerApply(
        spec: HerdrLayoutSpec,
        binding: HerdrTabBinding,
        workspace: Workspace
    ) {
        let key = binding.rootCmuxPaneId
        pendingDividerSpec[key] = spec
        if dividerApplyScheduled.contains(key) {
            return
        }
        dividerApplyScheduled.insert(key)
        // Honour the 30Hz throttle: schedule the dispatch for whenever
        // the next slot opens (immediate if we haven't applied recently
        // for this binding, otherwise asyncAfter at the first allowed
        // moment). pendingDividerSpec retains the latest spec so the
        // throttled dispatch still uses the final ratios.
        let last = lastDividerApplyAt[key] ?? .distantPast
        let elapsed = Date().timeIntervalSince(last)
        let work: () -> Void = {
            dividerApplyScheduled.remove(key)
            guard let latest = pendingDividerSpec.removeValue(forKey: key) else {
                return
            }
            guard let liveBinding = HerdrTabRegistry.shared.binding(forKey: key),
                  let liveWorkspace = liveBinding.workspace else {
                return
            }
            lastDividerApplyAt[key] = Date()
            applyDividers(spec: latest, binding: liveBinding, workspace: liveWorkspace)
        }
        if elapsed >= dividerApplyMinInterval {
            DispatchQueue.main.async(execute: work)
        } else {
            let waitMs = Int((dividerApplyMinInterval - elapsed) * 1000)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(1, waitMs)), execute: work)
        }
    }

    private static func applyDividers(
        spec: HerdrLayoutSpec,
        binding: HerdrTabBinding,
        workspace: Workspace
    ) {
        // Suppress outbound pane.resize for the duration of this apply
        // and a short trailing window. setDividerPosition triggers
        // bonsplit's didChangeGeometry, the panel resize observer, and
        // the 80ms forwardPanelSize debounce; without this guard the
        // first frame after each inbound LayoutChanged spawns an SSH
        // pane.resize round-trip that adds nothing (daemon is the one
        // that just told us the layout) and competes with the
        // raw-pty-attach output channel for the SSH master.
        inboundApplyActiveCount += 1
        defer {
            inboundApplyActiveCount -= 1
            inboundApplySuppressUntil = Date().addingTimeInterval(
                Double(inboundApplySuppressTrailingMs) / 1000.0
            )
        }
        let cmuxTree = workspace.bonsplitController.treeSnapshot()
        guard let cmuxSubtree = findCmuxSubtreeRoot(tree: cmuxTree, binding: binding) else {
            os_log("herdr.inbound.applyDividers no_subtree_match bound=%{public}d treeLeaves=%{public}d",
                   binding.paneBindings.count,
                   collectLeafCmuxIds(tree: cmuxTree).count)
            return
        }
        let newDividers = collectDividers(spec.root, prefix: [])
        var applied = 0
        var missed = 0
        for (path, ratio) in newDividers {
            guard let splitId = findSplitId(in: cmuxSubtree, atPath: path) else {
                missed += 1
                continue
            }
            workspace.bonsplitController.setDividerPosition(
                CGFloat(ratio),
                forSplit: splitId,
                fromExternal: true
            )
            applied += 1
        }
        os_log("herdr.inbound.applyDividers applied=%{public}d missed=%{public}d dividers=%{public}d",
               applied, missed, newDividers.count)
        // Seed lastSeen from bonsplit's ACTUAL post-apply state, not
        // from the spec ratios we asked for. setDividerPosition can
        // round / pixel-align the value it stores, and if we leave
        // lastSeen pointing at the spec ratio, the next
        // didChangeGeometry diffs the post-quantize value against the
        // pre-quantize lastSeen, the difference exceeds the 1e-3
        // epsilon, HerdrDividerSync.sync fires pane.set_split_ratio
        // back at the daemon, the daemon re-broadcasts LayoutChanged,
        // and we ping-pong forever. Locally that loop completes in
        // microseconds; over SSH each round-trip is ~100ms and the
        // user observes it as a frozen panel where typed input never
        // echoes (raw-pty-attach output is starved by the storm).
        let primed = HerdrDividerSync.prime(
            binding: binding,
            treeSnapshot: workspace.bonsplitController.treeSnapshot()
        )
        if !primed {
            // Post-apply tree shape didn't match this binding (mid-
            // structural transition: an addition Task is still pending,
            // a sibling pane was just removed, etc.). prime() no-ops in
            // that window, which used to leave lastSeen pointing at a
            // PREVIOUS tree's ratios — the next didChangeGeometry then
            // diffed the current ratios against ancient values, blew
            // through the epsilon, and fired pane.set_split_ratio RPCs
            // forever even though the user wasn't dragging. Fall back
            // to writing the spec ratios so lastSeen at least reflects
            // the layout the daemon just told us to draw.
            os_log(
                "herdr.inbound.applyDividers prime_skipped fallback_to_spec dividers=%{public}d",
                newDividers.count
            )
            HerdrDividerSync.setLastSeen(
                bindingKey: binding.rootCmuxPaneId,
                value: newDividers
            )
        }
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
        // Idempotency guard: a previous apply() Task may have already
        // bound this pane between its dispatch and ours (two
        // structural events in flight, second one recomputed `added`
        // from a still-stale binding snapshot). Without this check
        // the second Task would split the sibling a second time and
        // the user would see a duplicate pane.
        if binding.paneBindings.cmuxPaneId(forHerdrId: addedHerdrId) != nil {
            return
        }
        guard let parent = findParentSplit(node: spec.root, target: addedHerdrId) else {
            os_log(
                "herdr.inbound.applyAddition no_parent_split pane=%{public}@",
                addedHerdrId
            )
            return
        }
        guard let cmuxSiblingId = binding.paneBindings.cmuxPaneId(forHerdrId: parent.siblingHerdrId) else {
            os_log(
                "herdr.inbound.applyAddition sibling_unbound sibling=%{public}@ pane=%{public}@",
                parent.siblingHerdrId, addedHerdrId
            )
            return
        }

        let host = binding.host
        guard let exec = HerdrLocalBinary.resolve() else {
            os_log(
                "herdr.inbound.applyAddition no_binary pane=%{public}@",
                addedHerdrId
            )
            return
        }
        // Route through the host's transport factory so SSH hosts hit
        // their remote daemon over ssh stdio. Hardcoding LocalUDSTransport
        // here meant inbound TUI splits never resolved their pane.get
        // for SSH hosts and the cmux mirror stayed flat.
        let api = HerdrApiClient(transport: HerdrTransportFactory.make(host: host))
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

            // Honor daemon's focus designation: if the LayoutChanged
            // tree marks the just-added pane as focused (e.g. user
            // split via cmux mirror with focus:true, or TUI split key
            // focuses the new pane), let cmux focus it too. Without
            // this, mirror-mode user splits land focus on the source
            // pane while daemon thinks the new pane is focused —
            // typing goes to the wrong pane.
            let shouldFocus = (spec.focusedHerdrPaneId == addedHerdrId)
            _ = try await HerdrPanelOpener.wireHerdrBackedPanel(
                workspace: workspace,
                cmuxPaneId: newCmuxPaneId,
                host: host,
                terminalId: terminalId,
                herdrPaneId: addedHerdrId,
                executablePath: exec,
                socketPath: "",
                focus: shouldFocus
            )

            // Re-prime divider lastSeen so the geometry change from
            // this materialization doesn't echo back as a user drag.
            HerdrDividerSync.prime(
                binding: binding,
                treeSnapshot: workspace.bonsplitController.treeSnapshot()
            )
            os_log(
                "herdr.inbound.applyAddition wired pane=%{public}@ cmux=%{public}@",
                addedHerdrId, newCmuxPaneId.id.uuidString
            )
        } catch {
            os_log(
                "herdr.inbound.applyAddition wire_failed pane=%{public}@ err=%{public}@",
                addedHerdrId, error.localizedDescription
            )
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
