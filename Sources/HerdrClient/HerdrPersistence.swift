import Foundation

/// Persisted herdr workspace bindings per host. Keyed by host session
/// name; each entry holds the (workspace_id, tab_id) plus the cmux
/// Workspace UUID so that next-launch reattach lands the user back on
/// the same sidebar entries with the same daemon-side state.
///
/// Format on disk: `{ "<sessionName>": [ { workspace_id, tab_id,
/// cmux_workspace_id }, ... ] }`. Pre-cmux12 builds wrote a single
/// Entry per session (`{ "<sessionName>": { ... } }`); the loader
/// falls back to that shape so users don't lose their last binding
/// on the upgrade.
@MainActor
final class HerdrPersistence {
    static let shared = HerdrPersistence()

    struct Entry: Codable, Equatable {
        let workspaceId: String
        let tabId: String
        /// cmux Workspace UUID this herdr workspace was bound to.
        /// Optional for back-compat with pre-cmux10 entries.
        let cmuxWorkspaceId: UUID?

        enum CodingKeys: String, CodingKey {
            case workspaceId = "workspace_id"
            case tabId = "tab_id"
            case cmuxWorkspaceId = "cmux_workspace_id"
        }
    }

    private let url: URL
    private var cache: [String: [Entry]]

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

    /// Test-only init.
    init(url: URL) {
        self.url = url
        self.cache = Self.loadFromDisk(url: url)
    }

    /// All persisted bindings for a host session, in insertion order.
    func entries(forHostSession session: String) -> [Entry] {
        cache[session] ?? []
    }

    /// Append or update an entry. If a record for the same
    /// (workspaceId, tabId) already exists, update its cmuxWorkspaceId
    /// in place; otherwise append.
    func record(host: HerdrHost, workspaceId: String, tabId: String, cmuxWorkspaceId: UUID?) {
        var list = cache[host.sessionName] ?? []
        let entry = Entry(
            workspaceId: workspaceId,
            tabId: tabId,
            cmuxWorkspaceId: cmuxWorkspaceId
        )
        if let idx = list.firstIndex(where: {
            $0.workspaceId == workspaceId && $0.tabId == tabId
        }) {
            list[idx] = entry
        } else {
            list.append(entry)
        }
        cache[host.sessionName] = list
        saveToDisk()
    }

    /// Remove every binding for a host. Used when the daemon socket
    /// vanishes (`herdr session stop`) or the user revokes attachment.
    func clear(host: HerdrHost) {
        guard cache.removeValue(forKey: host.sessionName) != nil else { return }
        saveToDisk()
    }

    /// Remove a specific (workspaceId, tabId) binding for a host.
    /// Used when the user closes one cmux workspace but keeps others
    /// attached.
    func clearOne(host: HerdrHost, workspaceId: String, tabId: String) {
        guard var list = cache[host.sessionName] else { return }
        let before = list.count
        list.removeAll {
            $0.workspaceId == workspaceId && $0.tabId == tabId
        }
        if list.count == before { return }
        if list.isEmpty {
            cache.removeValue(forKey: host.sessionName)
        } else {
            cache[host.sessionName] = list
        }
        saveToDisk()
    }

    private static func loadFromDisk(url: URL) -> [String: [Entry]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        if let arrays = try? JSONDecoder().decode([String: [Entry]].self, from: data) {
            return arrays
        }
        if let singles = try? JSONDecoder().decode([String: Entry].self, from: data) {
            return singles.mapValues { [$0] }
        }
        return [:]
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
