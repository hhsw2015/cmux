import Combine
import Foundation

/// Live connection-health snapshot for each registered HerdrHost.
/// Drives the status dot rendered next to host names in Settings →
/// Hosts and the sidebar Hosts section. Health is observed lazily —
/// callers that already exercise a host's transport (open workspace,
/// install, probe) report results in here so we don't double-spend
/// SSH connections just for telemetry.
///
/// State semantics:
/// - `.unknown`     never tested in this session yet.
/// - `.checking`    a probe is in flight.
/// - `.online`      last attempt succeeded.
/// - `.offline`     last attempt failed (with the reason in `detail`).
@MainActor
final class HostHealthStore: ObservableObject {
    static let shared = HostHealthStore()

    enum HostStatus: Equatable {
        case unknown
        case checking
        case online
        case offline(reason: String)
    }

    struct HostHealth: Equatable {
        var status: HostStatus
        var checkedAt: Date?
    }

    @Published private(set) var healths: [UUID: HostHealth] = [:]

    private init() {}

    func health(for hostId: UUID) -> HostHealth {
        healths[hostId] ?? HostHealth(status: .unknown, checkedAt: nil)
    }

    /// Mark a host as online at this instant. Called from successful
    /// connect/install/RPC paths; cheap because it just stamps state
    /// without spinning up a fresh probe.
    func reportOnline(hostId: UUID) {
        healths[hostId] = HostHealth(status: .online, checkedAt: Date())
    }

    /// Mark a host as offline with a short user-facing reason. The
    /// reason should already be the friendly product copy, not raw
    /// errno text.
    func reportOffline(hostId: UUID, reason: String) {
        healths[hostId] = HostHealth(status: .offline(reason: reason), checkedAt: Date())
    }

    /// Mark a host as currently being probed. Toggle the dot to a
    /// muted state so the user sees we're acting on it.
    func reportChecking(hostId: UUID) {
        let prior = healths[hostId]
        healths[hostId] = HostHealth(status: .checking, checkedAt: prior?.checkedAt)
    }

    /// Drop a host's record entirely. Called when a host is removed
    /// from the registry so we don't keep stale UUIDs around.
    func forget(hostId: UUID) {
        healths.removeValue(forKey: hostId)
    }
}
