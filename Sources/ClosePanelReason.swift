import Foundation

/// Why a panel is being closed. The chokepoint
/// (`Workspace.discardClosedPanelLifecycleState`) consults this when
/// deciding whether to honor a panel's `keepAlive` flag.
///
/// Convention:
/// - `userExplicit`     → keep-alive honored (detach instead of kill)
/// - `userTerminate`    → keep-alive ignored (always kill, "Close & Terminate")
/// - `parentRemoved`    → keep-alive ignored (parent gone, no use detaching)
/// - `automated`        → default for internal/legacy callers; behaves like
///                        `userExplicit` so existing call sites keep their
///                        current behavior until we audit each one.
public enum ClosePanelReason: Sendable, Equatable {
    case userExplicit
    case userTerminate
    case parentRemoved
    case automated

    /// True when the close should respect a panel's keep-alive flag.
    public var honorsKeepAlive: Bool {
        switch self {
        case .userExplicit, .automated: return true
        case .userTerminate, .parentRemoved: return false
        }
    }
}
