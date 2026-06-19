import XCTest
@testable import CMUXSessionDaemon

private final class StubDeepBackend: DeepSessionDaemonBackend, @unchecked Sendable {
    let kind = SessionDaemonKind.tsm
    func locateBinary() -> URL? { nil }
    func version() -> String? { nil }
    func parseAttachInvocation(_ argv: [String]) -> ParsedDaemonAttach? { nil }
    func listSessions() async throws -> [DaemonSession] { [] }
    func isAlive(_ name: String) async -> Bool { false }
    func kill(_ name: String, force: Bool) async throws {}
    func createSession(name: String, cmd: String, dir: String) async throws {}
    func detachSession(_ name: String) async throws {}
    func listWorktrees() async throws -> [DaemonWorktree] { [] }
    func createWorktree(branch: String, base: String?) async throws {}
    func switchWorktree(branch: String) async throws {}
    func deleteWorktree(branch: String) async throws {}
    func eventStream() -> AsyncStream<DaemonEvent>? { nil }
}

final class BranchWorkspaceSwitcherTests: XCTestCase {
    private var tempDir: URL!
    private var store: ProjectManifestStore!
    private var switcher: BranchWorkspaceSwitcher!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-branch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = ProjectManifestStore(directory: tempDir)
        switcher = BranchWorkspaceSwitcher(backend: StubDeepBackend(), manifestStore: store)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testPlanReusesSavedBranchLayout() throws {
        let mainLayout: PanelLayoutTree = .panel(
            PanelDescriptor(sessionName: "main/editor", cmd: "nvim", dir: "/")
        )
        let featureLayout: PanelLayoutTree = .panel(
            PanelDescriptor(sessionName: "feature/editor", cmd: "nvim", dir: "/")
        )
        let manifest = ProjectManifest(
            name: "demo",
            layouts: ["main": mainLayout, "feature": featureLayout]
        )
        try store.save(manifest)

        let plan = try switcher.plan(
            project: "demo",
            from: "main",
            to: "feature",
            currentLayout: mainLayout,
            liveSessionNames: []
        )
        XCTAssertEqual(plan.toBranch, "feature")
        XCTAssertEqual(plan.layoutToMaterialize, featureLayout)
        XCTAssertEqual(plan.detachSessions, ["main/editor"])
        XCTAssertEqual(plan.sessionsToCreate.map(\.sessionName), ["feature/editor"])
    }

    func testPlanClonesCurrentLayoutForUnknownBranch() throws {
        let mainLayout: PanelLayoutTree = .split(
            direction: .horizontal,
            ratio: 0.6,
            children: [
                .panel(PanelDescriptor(sessionName: "main/editor", cmd: "nvim", dir: "/")),
                .panel(PanelDescriptor(sessionName: "main/server", cmd: "npm", dir: "/")),
            ]
        )
        let manifest = ProjectManifest(
            name: "demo",
            layouts: ["main": mainLayout]
        )
        try store.save(manifest)

        let plan = try switcher.plan(
            project: "demo",
            from: "main",
            to: "feature-x",
            currentLayout: mainLayout,
            liveSessionNames: []
        )
        let names = plan.layoutToMaterialize?.leaves.map(\.sessionName)
        XCTAssertEqual(names, ["feature-x/editor", "feature-x/server"])
        XCTAssertEqual(plan.sessionsToCreate.count, 2)

        // Cloned layout should have been persisted for next time.
        let reloaded = try store.load(name: "demo")
        XCTAssertNotNil(reloaded.layouts["feature-x"])
    }

    func testPlanReusesAlreadyLiveSessions() throws {
        let mainLayout: PanelLayoutTree = .panel(
            PanelDescriptor(sessionName: "main/editor", cmd: "nvim", dir: "/")
        )
        try store.save(ProjectManifest(name: "demo", layouts: ["main": mainLayout]))

        let plan = try switcher.plan(
            project: "demo",
            from: "main",
            to: "feat",
            currentLayout: mainLayout,
            liveSessionNames: ["feat/editor"]
        )
        XCTAssertTrue(plan.sessionsToCreate.isEmpty)
    }

    func testPlanThrowsForUnknownProject() {
        XCTAssertThrowsError(try switcher.plan(
            project: "missing",
            from: "main",
            to: "feature",
            currentLayout: nil,
            liveSessionNames: []
        )) { error in
            XCTAssertEqual(error as? BranchWorkspaceSwitcher.SwitchError, .projectNotFound)
        }
    }
}
