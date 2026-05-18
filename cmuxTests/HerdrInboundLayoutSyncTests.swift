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
}
