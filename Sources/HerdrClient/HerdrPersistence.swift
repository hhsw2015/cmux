import Foundation

/// Last-opened herdr workspace per host. Persists to disk so that the
/// next time the user clicks "Open Herdr Workspace" cmux reattaches
/// to the same workspace+tab they were on before — assuming the
/// daemon still has it (E5 detach guarantees that for the common
/// quit-cmux-and-reopen flow).
///
/// Format on disk: a single JSON object keyed by host session name
/// (matches `HerdrHost.sessionName`). Values are `{ workspace_id,
/// tab_id }` snapshots.
@MainActor
final class HerdrPersistence {
    static let shared = HerdrPersistence()

    struct Entry: Codable, Equatable {
        let workspaceId: String
        let tabId: String
        /// cmux Workspace UUID this herdr workspace was bound to.
        /// Persisted so that on next launch HerdrAutoReattach can reuse
        /// the existing cmux Workspace (now restored from cmux's normal
        /// state but no longer bound to herdr) instead of creating a
        /// fresh sibling — which left the user with two visually
        /// identical sidebar entries every quit/reopen cycle. Optional
        /// for back-compat with pre-cmux10 entries.
        let cmuxWorkspaceId: UUID?

        enum CodingKeys: String, CodingKey {
            case workspaceId = "workspace_id"
            case tabId = "tab_id"
            case cmuxWorkspaceId = "cmux_workspace_id"
        }
    }

    private let url: URL
    private var cache: [String: Entry]

    convenience init() {
        let bundleId = Bundle.main.bundleIdentifier ?? "cmux"
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("cmux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.init(url: dir.appendingPathComponent("herdr-bindings-\(bundleId).json"))
    }

    /// Test-only init: bypass the Application Support resolution so
    /// tests can use a temp file path and not pollute real cmux state.
    init(url: URL) {
        self.url = url
        self.cache = Self.loadFromDisk(url: url)
    }

    func entry(forHostSession session: String) -> Entry? {
        cache[session]
    }

    func record(host: HerdrHost, workspaceId: String, tabId: String, cmuxWorkspaceId: UUID?) {
        cache[host.sessionName] = Entry(
            workspaceId: workspaceId,
            tabId: tabId,
            cmuxWorkspaceId: cmuxWorkspaceId
        )
        saveToDisk()
    }

    func clear(host: HerdrHost) {
        guard cache.removeValue(forKey: host.sessionName) != nil else { return }
        saveToDisk()
    }

    private static func loadFromDisk(url: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
