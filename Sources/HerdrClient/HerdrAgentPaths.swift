import Foundation

/// Single source of truth for the herdr-cmux ("cmux agent") binary
/// name and the user-bin install location. Centralized so a future
/// rename (e.g. `cmux-agent`) or path move (e.g. `/usr/local/bin/`) is
/// a one-line change instead of a grep-and-replace audit across
/// installer, builder, and probe code.
enum HerdrAgentPaths {
    /// Bare binary name as published by the herdr fork's release
    /// (`herdr-{linux,macos}-{x86_64,aarch64}` get renamed to this on
    /// install) and as cmux looks for on the remote `$PATH`.
    static let binaryName = "herdr-cmux"

    /// `~/.local/bin/herdr-cmux` with `~` expanded. Used by both the
    /// local install path (HerdrLocalAgentInstaller) and as the herdr
    /// fork install location on the remote (HerdrRemoteInstaller's
    /// curl target). Mirrors what the user would do manually.
    static let userInstallPath: String =
        (("~/.local/bin/" + binaryName) as NSString).expandingTildeInPath

    /// Same path as written in shell scripts that run on the remote —
    /// keep it in tilde form so the remote shell expands `$HOME` for
    /// us instead of substituting cmux's local home directory.
    static let remoteUserInstallPath = "~/.local/bin/" + binaryName

    /// Directory containing the user-bin install path. Useful for
    /// `mkdir -p` calls before the install.
    static let remoteUserInstallDir = "~/.local/bin"
}
