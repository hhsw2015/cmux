import Foundation

/// Thin wrapper over `cmuxDebugLog` that prefixes every session-persistence
/// log line with a stable tag so users (and us) can grep one subsystem out
/// of the unified log without noise.
///
/// All call sites are wrapped in `#if DEBUG` to match the rest of cmux's
/// debug logging policy — release builds carry zero overhead.
enum SessionPersistenceLog {
    static let tag = "session-persistence"

    @inline(__always)
    static func event(_ event: String, _ details: @autoclosure () -> String = "") {
#if DEBUG
        let trimmed = details()
        let suffix = trimmed.isEmpty ? "" : " \(trimmed)"
        cmuxDebugLog("\(Self.tag).\(event)\(suffix)")
#endif
    }

    @inline(__always)
    static func engineSelected(_ kind: String?) {
#if DEBUG
        cmuxDebugLog("\(Self.tag).engine.selected kind=\(kind ?? "none")")
#endif
    }

    @inline(__always)
    static func sessionBound(panelId: UUID, sessionName: String) {
#if DEBUG
        cmuxDebugLog("\(Self.tag).session.bound panel=\(panelId.uuidString.prefix(8)) session=\(sessionName)")
#endif
    }

    @inline(__always)
    static func sessionUnbound(panelId: UUID) {
#if DEBUG
        cmuxDebugLog("\(Self.tag).session.unbound panel=\(panelId.uuidString.prefix(8))")
#endif
    }

    @inline(__always)
    static func reconcileFinished(lostCount: Int) {
#if DEBUG
        cmuxDebugLog("\(Self.tag).reconcile.finished lost=\(lostCount)")
#endif
    }

    @inline(__always)
    static func backendUnavailable(reason: String) {
#if DEBUG
        cmuxDebugLog("\(Self.tag).backend.unavailable reason=\(reason)")
#endif
    }

    @inline(__always)
    static func featureGate(_ feature: String, allowed: Bool) {
#if DEBUG
        cmuxDebugLog("\(Self.tag).feature.\(feature) allowed=\(allowed)")
#endif
    }
}
