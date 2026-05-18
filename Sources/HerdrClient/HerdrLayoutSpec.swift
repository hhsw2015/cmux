import Bonsplit
import CoreFoundation
import Foundation

/// Bridge type between herdr's wire `LayoutTree` and cmux's bonsplit
/// model. The spec carries the same tree shape but using cmux types
/// (`SplitOrientation`, `CGFloat`) so the workspace layer can apply it
/// without knowing about the wire schema.
///
/// E2 will turn one of these into actual `BonsplitController.splitPane`
/// calls; for E1 the spec is a pure value with helpers for walking,
/// counting, path-finding, and equality checks.
struct HerdrLayoutSpec: Equatable, Sendable {
    let workspaceId: String
    let tabId: String
    let root: HerdrLayoutSpecNode
    let focusedHerdrPaneId: String?
}

indirect enum HerdrLayoutSpecNode: Equatable, Sendable {
    case pane(herdrPaneId: String)
    case split(
        orientation: SplitOrientation,
        ratio: CGFloat,
        first: HerdrLayoutSpecNode,
        second: HerdrLayoutSpecNode
    )
}

extension HerdrLayoutSpec {
    init(from tree: HerdrLayoutTree) {
        self.init(
            workspaceId: tree.workspaceId,
            tabId: tree.tabId,
            root: HerdrLayoutSpecNode(from: tree.root),
            focusedHerdrPaneId: tree.focusedPaneId
        )
    }
}

extension HerdrLayoutSpecNode {
    init(from node: HerdrLayoutNode) {
        switch node {
        case .pane(let paneId):
            self = .pane(herdrPaneId: paneId)
        case .split(let direction, let ratio, let first, let second):
            self = .split(
                orientation: direction.bonsplitOrientation,
                ratio: CGFloat(ratio),
                first: HerdrLayoutSpecNode(from: first),
                second: HerdrLayoutSpecNode(from: second)
            )
        }
    }

    /// All herdr pane ids in left-first DFS order.
    var allHerdrPaneIds: [String] {
        switch self {
        case .pane(let id):
            return [id]
        case .split(_, _, let first, let second):
            return first.allHerdrPaneIds + second.allHerdrPaneIds
        }
    }

    /// Number of pane leaves in this subtree.
    var paneCount: Int {
        switch self {
        case .pane:
            return 1
        case .split(_, _, let first, let second):
            return first.paneCount + second.paneCount
        }
    }

    /// True if this subtree contains the given herdr pane id.
    func contains(herdrPaneId: String) -> Bool {
        switch self {
        case .pane(let id):
            return id == herdrPaneId
        case .split(_, _, let first, let second):
            return first.contains(herdrPaneId: herdrPaneId)
                || second.contains(herdrPaneId: herdrPaneId)
        }
    }

    /// Find the root-relative L/R path to the leaf pane carrying the
    /// given herdr id (`false` = first child, `true` = second child).
    /// Returns nil if the pane isn't in this subtree.
    func pathToPane(herdrId: String) -> [Bool]? {
        switch self {
        case .pane(let id):
            return id == herdrId ? [] : nil
        case .split(_, _, let first, let second):
            if let firstPath = first.pathToPane(herdrId: herdrId) {
                return [false] + firstPath
            }
            if let secondPath = second.pathToPane(herdrId: herdrId) {
                return [true] + secondPath
            }
            return nil
        }
    }

    /// Find the root-relative L/R path to the immediate parent split of
    /// the leaf carrying the given herdr id. Returns nil if the pane is
    /// not in this subtree, or if it is the root pane (no parent split).
    func pathToParentSplit(ofHerdrId herdrId: String) -> [Bool]? {
        switch self {
        case .pane:
            return nil
        case .split(_, _, let first, let second):
            // Direct child? then the path is the empty-prefix split (this).
            if case .pane(let id) = first, id == herdrId {
                return []
            }
            if case .pane(let id) = second, id == herdrId {
                return []
            }
            if let inner = first.pathToParentSplit(ofHerdrId: herdrId) {
                return [false] + inner
            }
            if let inner = second.pathToParentSplit(ofHerdrId: herdrId) {
                return [true] + inner
            }
            return nil
        }
    }

    /// Walk the subtree following an L/R path, returning the node at
    /// that position. Returns nil if the path runs off the tree.
    func node(atPath path: [Bool]) -> HerdrLayoutSpecNode? {
        if path.isEmpty {
            return self
        }
        guard case .split(_, _, let first, let second) = self else {
            return nil
        }
        return path[0]
            ? second.node(atPath: Array(path.dropFirst()))
            : first.node(atPath: Array(path.dropFirst()))
    }
}

extension HerdrLayoutSplitDirection {
    var bonsplitOrientation: SplitOrientation {
        switch self {
        case .horizontal:
            return .horizontal
        case .vertical:
            return .vertical
        }
    }
}

extension SplitOrientation {
    var herdrSplitDirection: HerdrLayoutSplitDirection {
        switch self {
        case .horizontal:
            return .horizontal
        case .vertical:
            return .vertical
        }
    }
}

/// One step in materializing a `HerdrLayoutSpec` onto bonsplit. Steps
/// reference panes by **slot index** rather than by `PaneID` because
/// the cmux side allocates real `PaneID`s only at execution time. Slot
/// 0 is the pre-existing root pane the executor was given; subsequent
/// slots are filled in order as `splitPane` calls return new pane ids.
enum HerdrLayoutApplyStep: Equatable {
    /// The leaf at `slot` represents this herdr pane id. The executor
    /// records the slot↔herdr mapping in `HerdrPaneBindingRegistry`
    /// and triggers its `paneFactory` to populate the cmux pane with
    /// a herdr-backed terminal surface.
    case bind(slot: Int, herdrPaneId: String)
    /// Split the pane currently at `targetSlot`. After execution, the
    /// original slot stays on the **first** side of the new split and
    /// the freshly created pane lands at `newSlot` on the **second**
    /// side. `ratio` is the divider position (first child's fraction).
    case split(targetSlot: Int, orientation: SplitOrientation, ratio: CGFloat, newSlot: Int)
}

/// Deterministic plan for materializing a `HerdrLayoutSpec` against
/// a bonsplit tree. Built purely from the spec — no `BonsplitController`
/// access required, so the algorithm is unit-testable. The executor
/// (E2b) walks `steps` in order, allocating cmux `PaneID`s into
/// `slotCount` slots starting with slot 0 = the given root pane.
struct HerdrLayoutApplyPlan: Equatable {
    let steps: [HerdrLayoutApplyStep]
    let slotCount: Int
    /// Slot index of the pane that should hold focus after the plan
    /// completes, or nil if the spec didn't include a focused pane id
    /// or it doesn't appear in the tree.
    let focusedSlot: Int?
}

extension HerdrLayoutApplyPlan {
    init(spec: HerdrLayoutSpec) {
        var steps: [HerdrLayoutApplyStep] = []
        var slotByHerdr: [String: Int] = [:]
        var nextSlot = 1
        Self.plan(
            node: spec.root,
            currentSlot: 0,
            nextSlot: &nextSlot,
            steps: &steps,
            slotByHerdr: &slotByHerdr
        )
        self.steps = steps
        self.slotCount = nextSlot
        self.focusedSlot = spec.focusedHerdrPaneId.flatMap { slotByHerdr[$0] }
    }

    private static func plan(
        node: HerdrLayoutSpecNode,
        currentSlot: Int,
        nextSlot: inout Int,
        steps: inout [HerdrLayoutApplyStep],
        slotByHerdr: inout [String: Int]
    ) {
        switch node {
        case .pane(let herdrId):
            slotByHerdr[herdrId] = currentSlot
            steps.append(.bind(slot: currentSlot, herdrPaneId: herdrId))
        case .split(let orientation, let ratio, let first, let second):
            let newSlot = nextSlot
            nextSlot += 1
            steps.append(
                .split(
                    targetSlot: currentSlot,
                    orientation: orientation,
                    ratio: ratio,
                    newSlot: newSlot
                )
            )
            plan(
                node: first,
                currentSlot: currentSlot,
                nextSlot: &nextSlot,
                steps: &steps,
                slotByHerdr: &slotByHerdr
            )
            plan(
                node: second,
                currentSlot: newSlot,
                nextSlot: &nextSlot,
                steps: &steps,
                slotByHerdr: &slotByHerdr
            )
        }
    }
}

/// Bidirectional binding between cmux bonsplit `PaneID`s (UUID-based)
/// and herdr public pane ids (string `w<n>-<m>` form). One registry per
/// herdr-backed cmux tab. E2 consumes this when sending mutation RPCs
/// or applying broadcast `LayoutChanged` events back into bonsplit.
@MainActor
final class HerdrPaneBindingRegistry {
    private var herdrToCmux: [String: UUID] = [:]
    private var cmuxToHerdr: [UUID: String] = [:]

    func bind(cmuxPaneId: UUID, herdrPaneId: String) {
        if let prevHerdr = cmuxToHerdr[cmuxPaneId] {
            herdrToCmux.removeValue(forKey: prevHerdr)
        }
        if let prevCmux = herdrToCmux[herdrPaneId] {
            cmuxToHerdr.removeValue(forKey: prevCmux)
        }
        cmuxToHerdr[cmuxPaneId] = herdrPaneId
        herdrToCmux[herdrPaneId] = cmuxPaneId
    }

    func unbind(cmuxPaneId: UUID) {
        guard let herdr = cmuxToHerdr.removeValue(forKey: cmuxPaneId) else { return }
        herdrToCmux.removeValue(forKey: herdr)
    }

    func unbind(herdrPaneId: String) {
        guard let cmux = herdrToCmux.removeValue(forKey: herdrPaneId) else { return }
        cmuxToHerdr.removeValue(forKey: cmux)
    }

    func cmuxPaneId(forHerdrId herdrPaneId: String) -> UUID? {
        herdrToCmux[herdrPaneId]
    }

    func herdrPaneId(forCmuxId cmuxPaneId: UUID) -> String? {
        cmuxToHerdr[cmuxPaneId]
    }

    var pairs: [(cmux: UUID, herdr: String)] {
        cmuxToHerdr.map { ($0.key, $0.value) }
    }

    var count: Int {
        cmuxToHerdr.count
    }
}
