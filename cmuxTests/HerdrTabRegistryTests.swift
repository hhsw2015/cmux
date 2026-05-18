import XCTest
@testable import cmux

@MainActor
final class HerdrTabRegistryTests: XCTestCase {
    private func makeBinding(
        rootCmuxPaneId: UUID = UUID(),
        cmuxPanes: [(UUID, String)] = []
    ) -> (HerdrTabBinding, HerdrPaneBindingRegistry) {
        let paneBindings = HerdrPaneBindingRegistry()
        for (cmux, herdr) in cmuxPanes {
            paneBindings.bind(cmuxPaneId: cmux, herdrPaneId: herdr)
        }
        let binding = HerdrTabBinding(
            host: HerdrHost.localhost(),
            workspaceId: "w1",
            tabId: "w1:1",
            rootCmuxPaneId: rootCmuxPaneId,
            paneBindings: paneBindings
        )
        return (binding, paneBindings)
    }

    func testBindingOwnsCmuxPanesInItsRegistry() {
        let cmuxA = UUID()
        let cmuxB = UUID()
        let (binding, _) = makeBinding(cmuxPanes: [(cmuxA, "w1-1"), (cmuxB, "w1-2")])
        XCTAssertTrue(binding.owns(cmuxPaneId: cmuxA))
        XCTAssertTrue(binding.owns(cmuxPaneId: cmuxB))
        XCTAssertFalse(binding.owns(cmuxPaneId: UUID()))
        XCTAssertEqual(binding.ownedCmuxPaneIds, [cmuxA, cmuxB])
    }

    func testRegistryLookupByCmuxPaneId() {
        let registry = HerdrTabRegistry()
        let cmuxA = UUID()
        let cmuxB = UUID()
        let cmuxC = UUID()
        let root1 = UUID()
        let root2 = UUID()
        let (binding1, _) = makeBinding(rootCmuxPaneId: root1, cmuxPanes: [(cmuxA, "w1-1"), (cmuxB, "w1-2")])
        let (binding2, _) = makeBinding(rootCmuxPaneId: root2, cmuxPanes: [(cmuxC, "w2-1")])
        registry.register(key: root1, binding: binding1)
        registry.register(key: root2, binding: binding2)
        XCTAssertEqual(registry.count, 2)
        XCTAssertTrue(registry.binding(forCmuxPaneId: cmuxA) === binding1)
        XCTAssertTrue(registry.binding(forCmuxPaneId: cmuxC) === binding2)
        XCTAssertNil(registry.binding(forCmuxPaneId: UUID()))
    }

    func testRegistryRemoveDropsTheBinding() {
        let registry = HerdrTabRegistry()
        let cmuxA = UUID()
        let root = UUID()
        let (binding, _) = makeBinding(rootCmuxPaneId: root, cmuxPanes: [(cmuxA, "w1-1")])
        registry.register(key: root, binding: binding)
        registry.remove(key: root)
        XCTAssertEqual(registry.count, 0)
        XCTAssertNil(registry.binding(forCmuxPaneId: cmuxA))
        XCTAssertNil(registry.binding(forKey: root))
    }
}
