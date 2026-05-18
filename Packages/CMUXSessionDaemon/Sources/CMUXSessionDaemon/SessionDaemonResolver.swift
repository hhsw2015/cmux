import Foundation

/// Picks the `SessionDaemonBackend` cmux should drive.
///
/// cmux callers ask for `SessionDaemonResolver.shared.activeBackend()`; the
/// resolver checks the user's selected engine (UserDefaults), the matching
/// binary's availability, and returns a backend or nil. nil → cmux runs in
/// "vanilla" mode and every persistence code path short-circuits.
public final class SessionDaemonResolver: @unchecked Sendable {
    public static let shared = SessionDaemonResolver()

    /// Settings key shared with `SessionPersistenceSettingsView`. Values:
    /// "" / "none" / "zmx" / "tsm". Empty defaults to none.
    public static let engineDefaultsKey = "session.persistence.engine"

    public init() {}

    public func selectedKind() -> SessionDaemonKind? {
        guard let raw = UserDefaults.standard.string(forKey: Self.engineDefaultsKey),
              !raw.isEmpty,
              raw.lowercased() != "none" else {
            return nil
        }
        return SessionDaemonKind(rawValue: raw.lowercased())
    }

    public func setSelectedKind(_ kind: SessionDaemonKind?) {
        if let kind {
            UserDefaults.standard.set(kind.rawValue, forKey: Self.engineDefaultsKey)
        } else {
            UserDefaults.standard.set("none", forKey: Self.engineDefaultsKey)
        }
    }

    /// Returns the backend matching the user's selection only if its binary
    /// is actually installed. Caller short-circuits on nil.
    public func activeBackend() -> SessionDaemonBackend? {
        guard let kind = selectedKind() else { return nil }
        switch kind {
        case .zmx:
            let backend = ZmxBackend()
            return backend.locateBinary() != nil ? backend : nil
        case .tsm:
            let backend = TsmBackend()
            return backend.locateBinary() != nil ? backend : nil
        case .herdr:
            // herdr backends are addressed per-host (one daemon per machine)
            // and are wired up in the cmux app layer via HostRegistry,
            // not through this global resolver. Returning nil here keeps
            // the legacy detach/reattach code paths untouched while
            // herdr-specific code goes through HerdrBackend directly.
            return nil
        }
    }

    /// Convenience: deep-capabilities check for callers gating Phase 4+
    /// features (project save/open, branch switching, event stream).
    public func activeDeepBackend() -> DeepSessionDaemonBackend? {
        activeBackend() as? DeepSessionDaemonBackend
    }
}
