import Bonsplit
import XCTest
@testable import cmux

@MainActor
final class HerdrInboundLayoutSyncTests: XCTestCase {
    // MARK: - findParentSplit

    func testFindParentSplitForLeafReturnsImmediateParent() {
        // Tree: split(h, 0.5, A, split(v, 0.6, B, C))
        let root = HerdrLayoutSpecNode.split(
            orientation: .horizontal,
            ratio: 0.5,
            first: .pane(herdrPaneId: "A"),
            second: .split(
                orientation: .vertical,
                ratio: 0.6,
                first: .pane(herdrPaneId: "B"),
                second: .pane(herdrPaneId: "C")
            )
        )

        let bParent = HerdrInboundLayoutSync.findParentSplit(node: root, target: "B")
        XCTAssertEqual(
            bParent,
            HerdrInboundLayoutSync.ParentSplit(
                orientation: .vertical,
                ratio: 0.6,
                siblingHerdrId: "C"
            )
        )

        let cParent = HerdrInboundLayoutSync.findParentSplit(node: root, target: "C")
        XCTAssertEqual(cParent?.siblingHerdrId, "B")

        let aParent = HerdrInboundLayoutSync.findParentSplit(node: root, target: "A")
        // A's sibling is the inner split, not a leaf, so we return nil
        // per the contract: pane.split always targets a leaf, so the
        // sibling of an added pane is also a leaf.
        XCTAssertNil(aParent)
    }

    func testFindParentSplitReturnsNilForRootPane() {
        let root = HerdrLayoutSpecNode.pane(herdrPaneId: "X")
        XCTAssertNil(HerdrInboundLayoutSync.findParentSplit(node: root, target: "X"))
    }

    func testFindParentSplitReturnsNilForUnknownPane() {
        let root = HerdrLayoutSpecNode.split(
            orientation: .horizontal,
            ratio: 0.5,
            first: .pane(herdrPaneId: "A"),
            second: .pane(herdrPaneId: "B")
        )
        XCTAssertNil(HerdrInboundLayoutSync.findParentSplit(node: root, target: "Z"))
    }

    // MARK: - collectDividers

    func testCollectDividersReturnsEmptyForLeaf() {
        let result = HerdrInboundLayoutSync.collectDividers(
            .pane(herdrPaneId: "A"),
            prefix: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testCollectDividersWalksNestedTree() {
        // h-split(0.5) over (A, v-split(0.6) over (B, C))
        let root = HerdrLayoutSpecNode.split(
            orientation: .horizontal,
            ratio: 0.5,
            first: .pane(herdrPaneId: "A"),
            second: .split(
                orientation: .vertical,
                ratio: 0.6,
                first: .pane(herdrPaneId: "B"),
                second: .pane(herdrPaneId: "C")
            )
        )
        let result = HerdrInboundLayoutSync.collectDividers(root, prefix: [])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[[]], 0.5)
        XCTAssertEqual(result[[true]], 0.6)
    }

    // MARK: - findSplitId

    func testFindSplitIdAtEmptyPath() {
        let id = UUID()
        let zero = PixelRect(x: 0, y: 0, width: 0, height: 0)
        let split = ExternalTreeNode.split(
            ExternalSplitNode(
                id: id.uuidString,
                orientation: "horizontal",
                dividerPosition: 0.5,
                first: .pane(ExternalPaneNode(id: UUID().uuidString, frame: zero, tabs: [], selectedTabId: nil)),
                second: .pane(ExternalPaneNode(id: UUID().uuidString, frame: zero, tabs: [], selectedTabId: nil))
            )
        )
        XCTAssertEqual(HerdrInboundLayoutSync.findSplitId(in: split, atPath: []), id)
    }

    func testFindSplitIdNestedPath() {
        let outer = UUID()
        let inner = UUID()
        let zero = PixelRect(x: 0, y: 0, width: 0, height: 0)
        let leaf: (UUID) -> ExternalTreeNode = { id in
            .pane(ExternalPaneNode(id: id.uuidString, frame: zero, tabs: [], selectedTabId: nil))
        }
        let tree = ExternalTreeNode.split(
            ExternalSplitNode(
                id: outer.uuidString,
                orientation: "horizontal",
                dividerPosition: 0.5,
                first: leaf(UUID()),
                second: .split(
                    ExternalSplitNode(
                        id: inner.uuidString,
                        orientation: "vertical",
                        dividerPosition: 0.7,
                        first: leaf(UUID()),
                        second: leaf(UUID())
                    )
                )
            )
        )
        XCTAssertEqual(HerdrInboundLayoutSync.findSplitId(in: tree, atPath: []), outer)
        XCTAssertEqual(HerdrInboundLayoutSync.findSplitId(in: tree, atPath: [true]), inner)
        // path past a leaf returns nil
        XCTAssertNil(HerdrInboundLayoutSync.findSplitId(in: tree, atPath: [false, true]))
    }

    func testFindSplitIdReturnsNilForLeafAtRoot() {
        let zero = PixelRect(x: 0, y: 0, width: 0, height: 0)
        let leaf = ExternalTreeNode.pane(
            ExternalPaneNode(id: UUID().uuidString, frame: zero, tabs: [], selectedTabId: nil)
        )
        XCTAssertNil(HerdrInboundLayoutSync.findSplitId(in: leaf, atPath: []))
        XCTAssertNil(HerdrInboundLayoutSync.findSplitId(in: leaf, atPath: [true]))
    }

    // MARK: - nextResolvableAddition (multi-change ordering)

    private func makeSpec(_ root: HerdrLayoutSpecNode) -> HerdrLayoutSpec {
        HerdrLayoutSpec(workspaceId: "ws", tabId: "t", root: root, focusedHerdrPaneId: nil)
    }

    func testNextResolvableAdditionPicksPaneWithBoundSibling() {
        // h-split(0.5, A, NEW) — A is bound, NEW is added.
        let spec = makeSpec(.split(
            orientation: .horizontal,
            ratio: 0.5,
            first: .pane(herdrPaneId: "A"),
            second: .pane(herdrPaneId: "NEW")
        ))
        let resolved = HerdrInboundLayoutSync.nextResolvableAddition(
            pending: ["NEW"],
            spec: spec,
            isBound: { $0 == "A" }
        )
        XCTAssertEqual(resolved, "NEW")
    }

    func testNextResolvableAdditionReturnsNilWhenSiblingNotBound() {
        // Both N1 and N2 are pending and siblings of each other —
        // neither has a bound sibling, caller should treat as stalled.
        let spec = makeSpec(.split(
            orientation: .horizontal,
            ratio: 0.5,
            first: .pane(herdrPaneId: "N1"),
            second: .pane(herdrPaneId: "N2")
        ))
        let resolved = HerdrInboundLayoutSync.nextResolvableAddition(
            pending: ["N1", "N2"],
            spec: spec,
            isBound: { _ in false }
        )
        XCTAssertNil(resolved)
    }

    func testNextResolvableAdditionDisjointMultiAdd() {
        // h-split(0.5, v-split(0.5, A, X), v-split(0.5, B, Y))
        // X and Y are added; their siblings A and B are bound.
        let spec = makeSpec(.split(
            orientation: .horizontal,
            ratio: 0.5,
            first: .split(
                orientation: .vertical,
                ratio: 0.5,
                first: .pane(herdrPaneId: "A"),
                second: .pane(herdrPaneId: "X")
            ),
            second: .split(
                orientation: .vertical,
                ratio: 0.5,
                first: .pane(herdrPaneId: "B"),
                second: .pane(herdrPaneId: "Y")
            )
        ))
        let bound: Set<String> = ["A", "B"]
        // First call resolves either X or Y.
        guard let first = HerdrInboundLayoutSync.nextResolvableAddition(
            pending: ["X", "Y"],
            spec: spec,
            isBound: { bound.contains($0) }
        ) else {
            XCTFail("expected at least one of X/Y to resolve")
            return
        }
        XCTAssertTrue(["X", "Y"].contains(first))

        // After processing `first`, the remaining pending also resolves.
        let other = HerdrInboundLayoutSync.nextResolvableAddition(
            pending: Set(["X", "Y"]).subtracting([first]),
            spec: spec,
            isBound: { bound.contains($0) }
        )
        XCTAssertNotNil(other)
    }

    func testNextResolvableAdditionChainedWhereNewIsSiblingOfNew() {
        // h-split(0.5, A, h-split(0.5, N1, N2)).
        // A bound; N1 and N2 both pending. Pass 1 should resolve
        // neither (each other's sibling is unbound and they're not
        // siblings of A in the parent split). After binding N1
        // externally, pass 2 resolves N2.
        let spec = makeSpec(.split(
            orientation: .horizontal,
            ratio: 0.5,
            first: .pane(herdrPaneId: "A"),
            second: .split(
                orientation: .horizontal,
                ratio: 0.5,
                first: .pane(herdrPaneId: "N1"),
                second: .pane(herdrPaneId: "N2")
            )
        ))
        // findParentSplit only returns when sibling is a leaf, so
        // N1's sibling is N2 and vice-versa. With only A bound, no
        // pending pane has a bound sibling.
        let resolved1 = HerdrInboundLayoutSync.nextResolvableAddition(
            pending: ["N1", "N2"],
            spec: spec,
            isBound: { $0 == "A" }
        )
        XCTAssertNil(resolved1, "neither N1 nor N2 has a bound sibling")
        // The fixed-point loop in production starts unbinding/binding
        // separately. Here, simulate that N1 was somehow bound first
        // (e.g. via a different code path or future relaxation):
        let resolved2 = HerdrInboundLayoutSync.nextResolvableAddition(
            pending: ["N2"],
            spec: spec,
            isBound: { $0 == "A" || $0 == "N1" }
        )
        XCTAssertEqual(resolved2, "N2")
    }
}
