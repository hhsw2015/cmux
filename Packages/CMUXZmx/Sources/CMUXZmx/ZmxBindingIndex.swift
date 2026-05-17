import Foundation

public actor ZmxBindingIndex {
    public static let shared = ZmxBindingIndex(storeURL: ZmxBindingIndex.defaultStoreURL())

    private let storeURL: URL
    private var cache: [UUID: RestorableZmxBinding] = [:]
    private var loaded = false

    public init(storeURL: URL) {
        self.storeURL = storeURL
    }

    public static func defaultStoreURL() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("cmux", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("zmx-bindings.json")
    }

    public func upsert(_ binding: RestorableZmxBinding) {
        ensureLoaded()
        cache[binding.panelId] = binding
        persist()
    }

    public func remove(panelId: UUID) {
        ensureLoaded()
        guard cache.removeValue(forKey: panelId) != nil else { return }
        persist()
    }

    public func update(panelId: UUID, state: RestorableZmxBinding.AttachState) {
        ensureLoaded()
        guard var binding = cache[panelId] else { return }
        binding.attachState = state
        binding.lastSeenAt = .init()
        cache[panelId] = binding
        persist()
    }

    public func lookup(panelId: UUID) -> RestorableZmxBinding? {
        ensureLoaded()
        return cache[panelId]
    }

    public func all() -> [RestorableZmxBinding] {
        ensureLoaded()
        return Array(cache.values)
    }

    public func all(workspaceId: UUID) -> [RestorableZmxBinding] {
        ensureLoaded()
        return cache.values.filter { $0.workspaceId == workspaceId }
    }

    /// Reconcile cached bindings against zmx daemon's known-alive set.
    /// Bindings whose session name is missing from `aliveSessions` are marked `lost`
    /// and returned for caller-side notifications. They are *not* removed from disk
    /// here so the UI can still surface a "session lost" badge after the next launch.
    @discardableResult
    public func reconcile(aliveSessions: Set<String>) -> [RestorableZmxBinding] {
        ensureLoaded()
        var lost: [RestorableZmxBinding] = []
        for (panelId, binding) in cache {
            if !aliveSessions.contains(binding.zmxSessionName) {
                if binding.attachState != .lost {
                    var updated = binding
                    updated.attachState = .lost
                    updated.lastSeenAt = .init()
                    cache[panelId] = updated
                    lost.append(updated)
                }
            }
        }
        if !lost.isEmpty { persist() }
        return lost
    }

    public func purge(panelIds: [UUID]) {
        ensureLoaded()
        var removed = false
        for id in panelIds {
            if cache.removeValue(forKey: id) != nil { removed = true }
        }
        if removed { persist() }
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: storeURL),
              !data.isEmpty else {
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let payload = try decoder.decode(IndexPayload.self, from: data)
            for binding in payload.bindings {
                cache[binding.panelId] = binding
            }
        } catch {
            // Corrupt file; back it up and start fresh.
            let backup = storeURL.deletingLastPathComponent()
                .appendingPathComponent("zmx-bindings.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: storeURL, to: backup)
        }
    }

    private func persist() {
        let payload = IndexPayload(version: 1, bindings: Array(cache.values))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    private struct IndexPayload: Codable {
        let version: Int
        let bindings: [RestorableZmxBinding]
    }
}
