import Bonsplit
import XCTest
@testable import cmux

/// Pure-data tests for the herdr ↔ bonsplit layout bridge. No daemon
/// required.
final class HerdrLayoutSpecTests: XCTestCase {
    private func sampleSpec() -> HerdrLayoutSpec {
        // Tree shape:
        //         h-split (0.5)
        //         /          \
        //   pane "w1-1"   v-split (0.6)
        //                  /        \
        //              pane "w1-2"  pane "w1-3"
        let tree = HerdrLayoutTree(
            workspaceId: "w1",
            tabId: "w1:1",
            root: .split(
                direction: .horizontal,
                ratio: 0.5,
                first: .pane(paneId: "w1-1"),
                second: .split(
                    direction: .vertical,
                    ratio: 0.6,
                    first: .pane(paneId: "w1-2"),
                    second: .pane(paneId: "w1-3")
                )
            ),
            focusedPaneId: "w1-2"
        )
        return HerdrLayoutSpec(from: tree)
    }

    func testInitFromTreeMapsDirectionsAndRatios() {
        let spec = sampleSpec()
        XCTAssertEqual(spec.workspaceId, "w1")
        XCTAssertEqual(spec.tabId, "w1:1")
        XCTAssertEqual(spec.focusedHerdrPaneId, "w1-2")
        guard case .split(let outerOrientation, let outerRatio, let firstNode, let secondNode) = spec.root else {
            return XCTFail("root should be a split")
        }
        XCTAssertEqual(outerOrientation, .horizontal)
        XCTAssertEqual(outerRatio, 0.5, accuracy: 1e-6)
        XCTAssertEqual(firstNode, .pane(herdrPaneId: "w1-1"))
        guard case .split(let innerOrientation, let innerRatio, _, _) = secondNode else {
            return XCTFail("second child should be a split")
        }
        XCTAssertEqual(innerOrientation, .vertical)
        XCTAssertEqual(innerRatio, 0.6, accuracy: 1e-6)
    }

    func testAllHerdrPaneIdsIsLeftFirstDfs() {
        XCTAssertEqual(sampleSpec().root.allHerdrPaneIds, ["w1-1", "w1-2", "w1-3"])
    }

    func testPaneCount() {
        XCTAssertEqual(sampleSpec().root.paneCount, 3)
        XCTAssertEqual(HerdrLayoutSpecNode.pane(herdrPaneId: "x").paneCount, 1)
    }

    func testPathToPane() {
        let spec = sampleSpec()
        XCTAssertEqual(spec.root.pathToPane(herdrId: "w1-1"), [false])
        XCTAssertEqual(spec.root.pathToPane(herdrId: "w1-2"), [true, false])
        XCTAssertEqual(spec.root.pathToPane(herdrId: "w1-3"), [true, true])
        XCTAssertNil(spec.root.pathToPane(herdrId: "w1-99"))
    }

    func testPathToParentSplit() {
        let spec = sampleSpec()
        // w1-1 sits directly under the root split.
        XCTAssertEqual(spec.root.pathToParentSplit(ofHerdrId: "w1-1"), [])
        // w1-2 sits directly under the inner v-split (path [true]).
        XCTAssertEqual(spec.root.pathToParentSplit(ofHerdrId: "w1-2"), [true])
        XCTAssertEqual(spec.root.pathToParentSplit(ofHerdrId: "w1-3"), [true])
        XCTAssertNil(spec.root.pathToParentSplit(ofHerdrId: "w1-99"))
    }

    func testNodeAtPath() {
        let spec = sampleSpec()
        XCTAssertEqual(spec.root.node(atPath: []), spec.root)
        XCTAssertEqual(spec.root.node(atPath: [false]), .pane(herdrPaneId: "w1-1"))
        XCTAssertEqual(spec.root.node(atPath: [true, false]), .pane(herdrPaneId: "w1-2"))
        XCTAssertNil(spec.root.node(atPath: [true, false, true]))
    }

    func testDirectionTranslationRoundTrips() {
        XCTAssertEqual(HerdrLayoutSplitDirection.horizontal.bonsplitOrientation, .horizontal)
        XCTAssertEqual(HerdrLayoutSplitDirection.vertical.bonsplitOrientation, .vertical)
        XCTAssertEqual(SplitOrientation.horizontal.herdrSplitDirection, .horizontal)
        XCTAssertEqual(SplitOrientation.vertical.herdrSplitDirection, .vertical)
    }

    @MainActor
    func testRegistryBindsAndLooksUpBothDirections() {
        let registry = HerdrPaneBindingRegistry()
        let cmuxA = UUID()
        let cmuxB = UUID()
        registry.bind(cmuxPaneId: cmuxA, herdrPaneId: "w1-1")
        registry.bind(cmuxPaneId: cmuxB, herdrPaneId: "w1-2")
        XCTAssertEqual(registry.cmuxPaneId(forHerdrId: "w1-1"), cmuxA)
        XCTAssertEqual(registry.herdrPaneId(forCmuxId: cmuxB), "w1-2")
        XCTAssertEqual(registry.count, 2)
    }

    @MainActor
    func testRegistryUnbindEvictsBothDirections() {
        let registry = HerdrPaneBindingRegistry()
        let cmuxA = UUID()
        registry.bind(cmuxPaneId: cmuxA, herdrPaneId: "w1-1")
        registry.unbind(cmuxPaneId: cmuxA)
        XCTAssertNil(registry.cmuxPaneId(forHerdrId: "w1-1"))
        XCTAssertNil(registry.herdrPaneId(forCmuxId: cmuxA))

        registry.bind(cmuxPaneId: cmuxA, herdrPaneId: "w1-1")
        registry.unbind(herdrPaneId: "w1-1")
        XCTAssertNil(registry.cmuxPaneId(forHerdrId: "w1-1"))
        XCTAssertNil(registry.herdrPaneId(forCmuxId: cmuxA))
    }

    func testPlanForSinglePaneIsJustABind() {
        let spec = HerdrLayoutSpec(
            workspaceId: "w1",
            tabId: "w1:1",
            root: .pane(herdrPaneId: "w1-1"),
            focusedHerdrPaneId: "w1-1"
        )
        let plan = HerdrLayoutApplyPlan(spec: spec)
        XCTAssertEqual(plan.steps, [.bind(slot: 0, herdrPaneId: "w1-1")])
        XCTAssertEqual(plan.slotCount, 1)
        XCTAssertEqual(plan.focusedSlot, 0)
    }

    func testPlanForSampleTreeMatchesExpectedSequence() {
        let plan = HerdrLayoutApplyPlan(spec: sampleSpec())
        XCTAssertEqual(plan.steps, [
            .split(targetSlot: 0, orientation: .horizontal, ratio: 0.5, newSlot: 1),
            .bind(slot: 0, herdrPaneId: "w1-1"),
            .split(targetSlot: 1, orientation: .vertical, ratio: 0.6, newSlot: 2),
            .bind(slot: 1, herdrPaneId: "w1-2"),
            .bind(slot: 2, herdrPaneId: "w1-3"),
        ])
        XCTAssertEqual(plan.slotCount, 3)
        XCTAssertEqual(plan.focusedSlot, 1)
    }

    func testPlanLeftSpineMaterializesRootPaneEachTime() {
        // Tree: split / split / pane "A" / pane "B" / pane "C"
        // The first child of the root is itself a split, so we keep
        // splitting slot 0 down the left spine. Slot 0 stays the
        // bottom-left leaf at the end.
        let spec = HerdrLayoutSpec(
            workspaceId: "w1",
            tabId: "w1:1",
            root: .split(
                orientation: .horizontal,
                ratio: 0.5,
                first: .split(
                    orientation: .horizontal,
                    ratio: 0.5,
                    first: .pane(herdrPaneId: "A"),
                    second: .pane(herdrPaneId: "B")
                ),
                second: .pane(herdrPaneId: "C")
            ),
            focusedHerdrPaneId: nil
        )
        let plan = HerdrLayoutApplyPlan(spec: spec)
        XCTAssertEqual(plan.steps, [
            .split(targetSlot: 0, orientation: .horizontal, ratio: 0.5, newSlot: 1),
            .split(targetSlot: 0, orientation: .horizontal, ratio: 0.5, newSlot: 2),
            .bind(slot: 0, herdrPaneId: "A"),
            .bind(slot: 2, herdrPaneId: "B"),
            .bind(slot: 1, herdrPaneId: "C"),
        ])
        XCTAssertEqual(plan.slotCount, 3)
        XCTAssertNil(plan.focusedSlot)
    }

    func testPlanFocusedSlotIsNilWhenIdMissing() {
        let spec = HerdrLayoutSpec(
            workspaceId: "w1",
            tabId: "w1:1",
            root: .pane(herdrPaneId: "w1-1"),
            focusedHerdrPaneId: "w1-99"
        )
        XCTAssertNil(HerdrLayoutApplyPlan(spec: spec).focusedSlot)
    }

    @MainActor
    func testRebindOverwritesPreviousMapping() {
        let registry = HerdrPaneBindingRegistry()
        let cmuxA = UUID()
        let cmuxB = UUID()
        registry.bind(cmuxPaneId: cmuxA, herdrPaneId: "w1-1")
        // Re-bind same cmux pane to a different herdr id: old herdr mapping is dropped.
        registry.bind(cmuxPaneId: cmuxA, herdrPaneId: "w1-2")
        XCTAssertNil(registry.cmuxPaneId(forHerdrId: "w1-1"))
        XCTAssertEqual(registry.cmuxPaneId(forHerdrId: "w1-2"), cmuxA)
        // Re-bind same herdr id to a different cmux pane: old cmux mapping is dropped.
        registry.bind(cmuxPaneId: cmuxB, herdrPaneId: "w1-2")
        XCTAssertNil(registry.herdrPaneId(forCmuxId: cmuxA))
        XCTAssertEqual(registry.herdrPaneId(forCmuxId: cmuxB), "w1-2")
    }
}
