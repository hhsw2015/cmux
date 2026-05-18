import Foundation

/// One host that runs (or could run) a herdr daemon. Localhost is a host
/// just like any remote machine — same protocol, same `HerdrHost` shape.
struct HerdrHost: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var transport: Transport
    var sessionName: String      // herdr `--session <name>` namespace
    let addedAt: Date

    /// Whether this is the auto-registered localhost entry. Localhost is
    /// always present and cannot be removed.
    var isLocalhost: Bool {
        if case .localUDS = transport { return true }
        return false
    }

    enum Transport: Codable, Equatable, Hashable, Sendable {
        /// Unix domain socket on the same machine. The session name is
        /// resolved via herdr's standard path lookup (`~/.config/herdr/...`).
        case localUDS
        /// SSH stdio bridge to a remote machine. `target` is anything ssh
        /// understands as the host argument (`user@host`, alias from
        /// `~/.ssh/config`, etc.).
        case sshStdio(target: String)
    }

    static let localhostID = UUID(uuidString: "00000000-0000-0000-0000-00000000C111")!

    static func localhost(sessionName: String? = nil) -> HerdrHost {
        HerdrHost(
            id: localhostID,
            displayName: "localhost",
            transport: .localUDS,
            sessionName: sessionName ?? Self.defaultLocalSessionName(),
            addedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// Per-bundle herdr session name so cmux / cmux DEV / cmux STAGING
    /// don't collide on each other's panes. Mirrors the bundle suffix
    /// rule used by the existing tagged debug socket scheme.
    static func defaultLocalSessionName() -> String {
        let bundleID = Bundle.main.bundleIdentifier ?? "cmux"
        let lower = bundleID.lowercased()
        if lower.contains("staging") { return "cmux-staging" }
        if lower.contains("debug") || lower.contains("dev") { return "cmux-dev" }
        return "cmux"
    }
}
