import Combine
import Foundation

/// Persistent registry of herdr hosts. Localhost is always present and
/// auto-registered. Other entries persist to JSON in the app support
/// directory and survive launches.
///
/// Lives at `@MainActor` so SwiftUI views can observe `@Published hosts`
/// directly without bridging.
@MainActor
final class HostRegistry: ObservableObject {
    static let shared = HostRegistry()

    @Published private(set) var hosts: [HerdrHost] = []

    private let storeURL: URL

    init(storeURL: URL? = nil) {
        if let url = storeURL {
            self.storeURL = url
        } else {
            let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent("cmux", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: support, withIntermediateDirectories: true
            )
            self.storeURL = support.appendingPathComponent("hosts.json")
        }
        load()
    }

    /// Add or update a non-localhost host. Returns false if the host id
    /// already exists with a different transport (caller should pick a
    /// different name) — callers normally update via `update(_:)` instead.
    @discardableResult
    func add(_ host: HerdrHost) -> Bool {
        guard !host.isLocalhost else { return false }
        if let existing = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[existing] = host
        } else {
            hosts.append(host)
        }
        persist()
        return true
    }

    func update(_ host: HerdrHost) {
        guard let idx = hosts.firstIndex(where: { $0.id == host.id }) else {
            return
        }
        // Localhost displayName/sessionName can be edited; transport is fixed.
        if host.isLocalhost {
            var preserved = host
            preserved = HerdrHost(
                id: HerdrHost.localhostID,
                displayName: host.displayName,
                transport: .localUDS,
                sessionName: host.sessionName,
                addedAt: hosts[idx].addedAt
            )
            hosts[idx] = preserved
        } else {
            hosts[idx] = host
        }
        persist()
    }

    func remove(id: UUID) {
        guard id != HerdrHost.localhostID else { return }
        hosts.removeAll { $0.id == id }
        persist()
    }

    func host(id: UUID) -> HerdrHost? {
        hosts.first { $0.id == id }
    }

    // MARK: - Persistence

    private func load() {
        var loaded: [HerdrHost] = []
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode([HerdrHost].self, from: data) {
            loaded = decoded
        }
        // Always prepend localhost (or replace existing localhost row with
        // canonical id so older stores converge).
        loaded.removeAll { $0.id == HerdrHost.localhostID }
        loaded.insert(HerdrHost.localhost(), at: 0)
        hosts = loaded
    }

    private func persist() {
        // Localhost is implicit; don't write it to disk so future schema
        // tweaks for localhost don't fight stale serialized state.
        let nonLocal = hosts.filter { !$0.isLocalhost }
        guard let data = try? JSONEncoder().encode(nonLocal) else { return }
        try? data.write(to: storeURL, options: [.atomic])
    }
}
