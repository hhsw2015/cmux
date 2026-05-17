import XCTest
@testable import CMUXZmx

final class ProjectManifestTests: XCTestCase {
    func testLeavesFlattenSplitTree() {
        let tree: PanelLayoutTree = .split(
            direction: .horizontal,
            ratio: 0.6,
            children: [
                .panel(PanelDescriptor(sessionName: "editor", cmd: "nvim .", dir: "/tmp")),
                .split(
                    direction: .vertical,
                    ratio: 0.5,
                    children: [
                        .panel(PanelDescriptor(sessionName: "server", cmd: "npm run dev", dir: "/tmp")),
                        .panel(PanelDescriptor(sessionName: "tests", cmd: "npm test", dir: "/tmp")),
                    ]
                ),
            ]
        )
        XCTAssertEqual(tree.leaves.map(\.sessionName), ["editor", "server", "tests"])
    }

    func testCodableRoundTrip() throws {
        let original = ProjectManifest(
            name: "my-app",
            rootDirectory: "/Users/me/my-app",
            layouts: [
                ProjectManifest.defaultBranchKey: .panel(
                    PanelDescriptor(sessionName: "shell", cmd: "zsh", dir: "/Users/me/my-app")
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProjectManifest.self, from: data)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.rootDirectory, original.rootDirectory)
        XCTAssertEqual(decoded.layouts.count, 1)
    }
}

final class ProjectManifestStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: ProjectManifestStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-projects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = ProjectManifestStore(directory: tempDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSaveLoadRoundTrip() throws {
        let manifest = ProjectManifest(
            name: "demo",
            layouts: [
                ProjectManifest.defaultBranchKey: .panel(
                    PanelDescriptor(sessionName: "demo", cmd: "zsh", dir: "/")
                )
            ]
        )
        try store.save(manifest)
        let loaded = try store.load(name: "demo")
        XCTAssertEqual(loaded.name, "demo")
        XCTAssertEqual(loaded.layouts.count, 1)
    }

    func testList() throws {
        try store.save(.init(name: "alpha", layouts: [:]))
        try store.save(.init(name: "beta", layouts: [:]))
        XCTAssertEqual(try store.list(), ["alpha", "beta"])
    }

    func testDelete() throws {
        try store.save(.init(name: "tmp", layouts: [:]))
        try store.delete(name: "tmp")
        XCTAssertEqual(try store.list(), [])
    }

    func testSanitizeStripsPathSeparators() {
        XCTAssertEqual(ProjectManifestStore.sanitize("../etc/passwd"), "..-etc-passwd")
        XCTAssertEqual(ProjectManifestStore.sanitize("a/b\\c:d"), "a-b-c-d")
        XCTAssertEqual(ProjectManifestStore.sanitize(""), "untitled")
        XCTAssertEqual(ProjectManifestStore.sanitize("   "), "untitled")
    }
}
