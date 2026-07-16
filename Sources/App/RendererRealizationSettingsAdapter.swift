import Foundation

// Fork-side adapter: PR #5857 introduced RendererRealizationSettings as a
// rename/replacement for SurfaceHibernationSettings. The fork keeps the
// SurfaceHibernation* surface (it remains the user-facing knob), so this
// adapter maps the new type's three-field shape onto the existing settings
// store and notification name.
enum RendererRealizationSettings {
    struct Values: Equatable, Sendable {
        var enabled: Bool
        var idleSeconds: TimeInterval
        var maxWarmRenderers: Int
    }

    static let didChangeNotification = SurfaceHibernationSettings.didChangeNotification

    static let enabledKey = "surfaceHibernationEnabled"
    static let idleSecondsKey = "surfaceHibernationIdleSeconds"
    static let maxWarmRenderersKey = "surfaceHibernationMaxLiveSurfaces"

    static func sanitizedIdleSeconds(_ candidate: TimeInterval) -> TimeInterval {
        min(max(candidate, 60), 86400 * 30)
    }

    static func sanitizedMaxWarmRenderers(_ candidate: Int) -> Int {
        min(max(candidate, 1), 200)
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }

    static func values(defaults: UserDefaults = .standard) -> Values {
        let v = SurfaceHibernationSettings.values(defaults: defaults)
        return Values(
            enabled: v.enabled,
            idleSeconds: v.idleSeconds,
            maxWarmRenderers: v.maxLiveSurfaces
        )
    }
}
