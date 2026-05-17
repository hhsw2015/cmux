import Foundation

/// Lightweight session-level tracking that doesn't depend on a panel<->pid map.
///
/// `ZmxBindingIndex` stores `(workspaceId, panelId) -> session` records.
/// Wiring those panelIds requires Ghostty PTY plumbing cmux doesn't currently
/// expose. As a pragmatic MVP we additionally maintain a flat
/// `[sessionName -> originalArgv]` index so the system knows *which sessions
/// have ever existed in this cmux user's environment*. Future work can layer
/// proper panel binding on top once Ghostty surfaces a pid.
public actor ZmxKnownSessionsTracker {
    public static let shared = ZmxKnownSessionsTracker(
        storeURL: ZmxKnownSessionsTracker.defaultStoreURL()
    )

    private let storeURL: URL
    private var cache: [String: KnownSession] = [:]
    private var loaded = false

    public struct KnownSession: Codable, Sendable, Equatable {
        public let sessionName: String
        public let originalArgv: [String]
        public let firstSeenAt: Date
        public var lastSeenAt: Date
    }

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
        return dir.appendingPathComponent("zmx-known-sessions.json")
    }

    /// Apply a fresh sweep of live `zmx attach` invocations. Sessions that
    /// disappear from the live set are *kept* in the index until reconcile
    /// removes them — that lets the next launch see "this session went
    /// away while cmux was off" cleanly.
    public func record(live: [ZmxSystemScanner.LiveAttach]) {
        ensureLoaded()
        var changed = false
        let now = Date()
        for attach in live {
            if var existing = cache[attach.sessionName] {
                existing.lastSeenAt = now
                cache[attach.sessionName] = existing
                changed = true
            } else {
                cache[attach.sessionName] = KnownSession(
                    sessionName: attach.sessionName,
                    originalArgv: attach.argv,
                    firstSeenAt: now,
                    lastSeenAt: now
                )
                changed = true
            }
        }
        if changed { persist() }
    }

    public func remove(sessionName: String) {
        ensureLoaded()
        guard cache.removeValue(forKey: sessionName) != nil else { return }
        persist()
    }

    public func all() -> [KnownSession] {
        ensureLoaded()
        return Array(cache.values)
    }

    /// Drop entries whose name is not in `aliveSessions`.
    @discardableResult
    public func reconcile(aliveSessions: Set<String>) -> [KnownSession] {
        ensureLoaded()
        let staleNames = cache.keys.filter { !aliveSessions.contains($0) }
        let stale = staleNames.compactMap { cache[$0] }
        for name in staleNames { cache.removeValue(forKey: name) }
        if !staleNames.isEmpty { persist() }
        return stale
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: storeURL), !data.isEmpty else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let payload = try decoder.decode(Payload.self, from: data)
            for entry in payload.sessions {
                cache[entry.sessionName] = entry
            }
        } catch {
            let backup = storeURL.deletingLastPathComponent()
                .appendingPathComponent("zmx-known-sessions.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: storeURL, to: backup)
        }
    }

    private func persist() {
        let payload = Payload(version: 1, sessions: Array(cache.values))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storeURL, options: .atomic)
    }

    private struct Payload: Codable {
        let version: Int
        let sessions: [KnownSession]
    }
}
