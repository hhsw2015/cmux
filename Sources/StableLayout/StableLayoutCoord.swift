import Foundation

/// Position-derived fingerprint that survives UUID regeneration on session restore.
///
/// cmux assigns volatile UUIDs to workspaces, layout tabs, panes, and panels. When the
/// snapshot file is replayed onto a fresh process those UUIDs are re-minted from
/// scratch, so a snapshot keyed only by UUID cannot rebind its panels back to the right
/// surfaces — every pane shows up empty until the user manually reattaches it.
///
/// `StableLayoutCoord` is a tuple of human-meaningful identifiers
/// (`workspaceTitle / topTabTitle / splitPath / paneIndex / panelIndexInPane`) that the
/// snapshot writer captures alongside the UUIDs. On restore the loader first tries to
/// match by UUID; if that fails it falls back to the stable coord, which lets cmux
/// recover a layout even after a database wipe, an OS reinstall, or a manual import of
/// somebody else's snapshot.
///
/// The format is intentionally string-based and JSON-friendly so blueprints
/// (`Phase 1.2`) and external tools (e.g. JacianLiu/cmux-claude-session) can construct
/// the same coordinates without linking against cmux.
///
/// Example:
/// ```swift
/// let coord = StableLayoutCoord(
///     workspaceTitle: "cmux",
///     topTabTitle: "backend",
///     splitPath: "R/B",
///     paneIndex: 0,
///     panelIndexInPane: 1
/// )
/// // string form: "cmux\u{1F}backend\u{1F}R/B\u{1F}0\u{1F}1"
/// ```
struct StableLayoutCoord: Codable, Hashable, Sendable {
    /// Title of the owning workspace at snapshot time. Empty string if the workspace
    /// is untitled — both reads and writes treat empty and `nil` as equivalent so
    /// "" / nil drift between Codable encoders does not break matching.
    var workspaceTitle: String

    /// Title of the top tab (Ghostty-style layout tab) that owns this pane tree, or
    /// `nil` for the legacy single-tab workspace layout. Falls back to `""` for the
    /// implicit default tab so coordinates remain stable when a user adds a top tab
    /// later.
    var topTabTitle: String?

    /// Slash-separated path through the bonsplit binary tree from the layout root
    /// down to the leaf pane. `L` = left/top child, `R` = right/bottom child.
    /// Empty string for the single-pane root. Example: `"L/R/L"`.
    var splitPath: String

    /// 0-based index of the leaf pane inside its parent split's child list. For a
    /// strict binary tree this is always 0 or 1; the field exists for future
    /// non-binary layouts and doubles as a tie-breaker if `splitPath` is ever
    /// degenerate.
    var paneIndex: Int

    /// 0-based index of this panel inside its pane's panel list. A pane can host
    /// multiple panels (e.g. terminal + browser) addressed by this index. Defaults
    /// to 0 for single-panel panes.
    var panelIndexInPane: Int

    /// Round-trippable string form. Uses ASCII Unit Separator (`\u{1F}`) so titles
    /// containing slashes or colons remain unambiguous.
    var rawValue: String {
        let parts: [String] = [
            workspaceTitle,
            topTabTitle ?? "",
            splitPath,
            String(paneIndex),
            String(panelIndexInPane)
        ]
        return parts.joined(separator: "\u{1F}")
    }

    init(
        workspaceTitle: String,
        topTabTitle: String?,
        splitPath: String,
        paneIndex: Int,
        panelIndexInPane: Int
    ) {
        self.workspaceTitle = workspaceTitle
        self.topTabTitle = topTabTitle
        self.splitPath = splitPath
        self.paneIndex = paneIndex
        self.panelIndexInPane = panelIndexInPane
    }

    /// Parse a `rawValue` back into a coord, or `nil` if the string is not the
    /// expected 5-segment shape.
    init?(rawValue: String) {
        let parts = rawValue.split(separator: "\u{1F}", omittingEmptySubsequences: false)
        guard parts.count == 5 else { return nil }
        guard let pi = Int(parts[3]), let pii = Int(parts[4]) else { return nil }
        self.workspaceTitle = String(parts[0])
        let tab = String(parts[1])
        self.topTabTitle = tab.isEmpty ? nil : tab
        self.splitPath = String(parts[2])
        self.paneIndex = pi
        self.panelIndexInPane = pii
    }
}
