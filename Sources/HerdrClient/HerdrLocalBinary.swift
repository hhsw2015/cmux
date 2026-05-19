import Foundation

/// Resolves the local `herdr-cmux` binary path. The build phase
/// `Bundle herdr-cmux` copies the binary into the app bundle when
/// available; fall back to `~/.local/bin/herdr-cmux` (dev install)
/// otherwise. Cached on first hit since the answer doesn't change
/// across the process lifetime.
enum HerdrLocalBinary {
    private static var cached: String?

    /// Returns the absolute path to a usable herdr-cmux binary, or
    /// nil if neither the bundled copy nor the dev fallback exists.
    static func resolve() -> String? {
        if let cached, FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }
        let candidates: [String] = [
            Bundle.main.path(forResource: "herdr-cmux", ofType: nil, inDirectory: "bin"),
            (("~/.local/bin/herdr-cmux") as NSString).expandingTildeInPath
        ].compactMap { $0 }
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                cached = candidate
                return candidate
            }
        }
        return nil
    }

    /// Path the user is expected to install the dev fallback at —
    /// shown by the missing-binary alert.
    static let userInstallPath: String = (("~/.local/bin/herdr-cmux") as NSString).expandingTildeInPath
}
