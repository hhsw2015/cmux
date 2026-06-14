import Foundation

// ponytail: P45 stubs for fork-only methods removed during decomp.
extension GhosttyConfig {
    static func shouldApplyManagedDefaultAppearance(configPaths: [String]) -> Bool { false }
    struct AppearanceSummaryStub { var lastThemeDirective: String? = nil }
    static func userAppearanceConfigSummary(configPaths: [String]) -> AppearanceSummaryStub { AppearanceSummaryStub() }
    func previewConfigContents(preferredColorScheme: GhosttyConfig.ColorSchemePreference) -> String { "" }
}

extension GhosttyConfig {
    static func explicitConditionalThemeName(from rawValue: Any, preferredColorScheme: GhosttyConfig.ColorSchemePreference) -> String? { nil }
}
