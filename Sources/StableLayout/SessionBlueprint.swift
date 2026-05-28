import Foundation

/// Human-readable Markdown projection of an `AppSessionSnapshot`.
///
/// Inspired by drolosoft/cmux-resurrect: the user can export a snapshot, manually
/// edit cwds / launch commands / pane order in a regular text editor or commit
/// the file to git, and re-apply it. Round-trip identity is best-effort —
/// the blueprint stores the panel's launch identity (kind + cwd + command), not
/// runtime scrollback or transient UI state.
///
/// The format is intentionally line-oriented and parseable by hand, so external
/// tools (CI, agent prompts, Obsidian) can author or read blueprints without
/// linking against cmux.
///
/// Schema (v1):
/// ```text
/// # cmux blueprint v1
/// created: 2026-05-28T11:00:00Z
///
/// ## Workspace: <title>  (cwd: <path>)
///
/// ### Top tab: <name>          # omitted if workspace has no layoutTabs
///
/// - <splitPath>: <kind> `<command>`  (cwd: <path>)
/// ```
///
/// `<splitPath>` follows `StableLayoutCoord.splitPath`: `root` for a single
/// pane, otherwise slash-joined `L`/`R` segments. `<kind>` is one of
/// `terminal | browser | markdown | filepreview | rightSidebarTool`. The
/// command field is backtick-quoted; for non-terminal kinds it carries the
/// initial URL or path instead.
struct SessionBlueprint: Equatable, Sendable {
    var version: Int
    var createdAt: Date
    var workspaces: [Workspace]

    struct Workspace: Equatable, Sendable {
        var title: String
        var cwd: String
        var topTabs: [TopTab]
    }

    /// A workspace's top tab. Workspaces without explicit top tabs are encoded
    /// as a single `TopTab` with `name == nil`.
    struct TopTab: Equatable, Sendable {
        var name: String?
        var entries: [Entry]
    }

    /// One leaf panel inside a top tab's split tree.
    struct Entry: Equatable, Sendable {
        var splitPath: String
        var kind: String
        var command: String
        var cwd: String?
    }
}
