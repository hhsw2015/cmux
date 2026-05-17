import Foundation

/// Feature flags for cmux's session-persistence integration.
///
/// Each flag has three layers, checked in order: environment variable,
/// UserDefaults, compile-time default. Any flag can be flipped off without a
/// rebuild so a regression in one phase doesn't block the rest.
public enum SessionPersistenceFeature: String, CaseIterable, Sendable {
    /// Master switch. Off → every code path short-circuits to vanilla cmux.
    case engine
    /// Phase 2: panel "Keep Alive" toggle and detach-on-close behavior.
    case keepAlive
    /// Phase 3: sidebar "Background" section listing detached sessions.
    case background
    /// Phase 4: project save/open with full layout serialization.
    case projects
    /// Phase 5: tsm daemon event stream (vs polling fallback).
    case eventStream
    /// Phase 6: git branch ↔ workspace switching via tsm worktrees.
    case branchWorkspace
    /// Phase 7: merge tsm-reported agent state into the cmux feed.
    case agentMerge
    /// Phase 8: panel exit banner with Restart / Close.
    case exitBanner

    /// UserDefaults key (single namespace so cmux's existing settings UI can
    /// read/write without colliding with other modules).
    public var defaultsKey: String {
        "session.persistence.\(rawValue).enabled"
    }

    /// Environment variable name. Lets dogfood builds force-enable without
    /// touching settings.
    public var envKey: String {
        "CMUX_SESSION_PERSISTENCE_\(rawValue.uppercased())"
    }

    /// Compile-time default. DEBUG builds opt every flag in for internal
    /// dogfood; release builds keep them off until the user flips them on.
    public var compileTimeDefault: Bool {
#if DEBUG
        return true
#else
        return false
#endif
    }
}

/// Sole source of truth for runtime flag state. Read it from anywhere; the
/// closure under test can swap in a deterministic implementation.
public struct SessionPersistenceFeatureFlagReader: Sendable {
    public let isEnabled: @Sendable (SessionPersistenceFeature) -> Bool

    public init(isEnabled: @escaping @Sendable (SessionPersistenceFeature) -> Bool) {
        self.isEnabled = isEnabled
    }

    public static let `default` = SessionPersistenceFeatureFlagReader { feature in
        // 1. Environment override (dogfood, CI)
        if let raw = ProcessInfo.processInfo.environment[feature.envKey] {
            switch raw.lowercased() {
            case "1", "on", "true", "yes": return true
            case "0", "off", "false", "no": return false
            default: break
            }
        }
        // 2. UserDefaults (settings UI)
        if let value = UserDefaults.standard.object(forKey: feature.defaultsKey) as? Bool {
            return value
        }
        // 3. Compile-time default
        return feature.compileTimeDefault
    }
}

public enum SessionPersistenceFeatureFlags {
    /// Mutable for tests; production reads from `.default`.
    /// `nonisolated(unsafe)` is acceptable here because:
    /// - production code only reads
    /// - tests own this single-threaded during `setUp`/`tearDown`
    /// - the closure inside the reader is itself `@Sendable`
    public nonisolated(unsafe) static var current: SessionPersistenceFeatureFlagReader = .default

    public static func isEnabled(_ feature: SessionPersistenceFeature) -> Bool {
        current.isEnabled(feature)
    }

    /// Engine itself acts as a master gate: a feature is *effectively* on only
    /// when the master engine flag is also on. Saves callers a guard pyramid.
    public static func effective(_ feature: SessionPersistenceFeature) -> Bool {
        guard isEnabled(.engine) else { return false }
        if feature == .engine { return true }
        return isEnabled(feature)
    }
}
