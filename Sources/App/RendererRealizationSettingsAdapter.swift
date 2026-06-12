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

    static func values(defaults: UserDefaults = .standard) -> Values {
        let v = SurfaceHibernationSettings.values(defaults: defaults)
        return Values(
            enabled: v.enabled,
            idleSeconds: v.idleSeconds,
            maxWarmRenderers: v.maxLiveSurfaces
        )
    }
}
