#if DEBUG
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

        enum CodingKeys: String, CodingKey {
            case workspaceId = "workspace_id"
            case tabId = "tab_id"
        }
    }

    private let url: URL
    private var cache: [String: Entry]

    init() {
        let bundleId = Bundle.main.bundleIdentifier ?? "cmux"
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("cmux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("herdr-bindings-\(bundleId).json")
        cache = Self.loadFromDisk(url: url)
    }

    func entry(forHostSession session: String) -> Entry? {
        cache[session]
    }

    func record(host: HerdrHost, workspaceId: String, tabId: String) {
        cache[host.sessionName] = Entry(workspaceId: workspaceId, tabId: tabId)
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
#endif
