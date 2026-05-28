import Foundation

/// Reverse lookup table built from a stamped snapshot: stable coord -> panel id.
///
/// Used during restore to recover panels whose UUIDs no longer exist in the live
/// session (e.g. snapshot imported from another machine, panel database was wiped).
/// The resolver is value-typed and immutable; build it once per restore pass and reuse
/// it for every UUID lookup.
struct StableLayoutCoordResolver {
    private let coordToPanelId: [StableLayoutCoord: UUID]

    /// Build a resolver from the panels in a freshly loaded snapshot. Panels without
    /// a `stableCoord` (older snapshots predating Phase 1.1) are skipped.
    init(snapshot: AppSessionSnapshot) {
        var map: [StableLayoutCoord: UUID] = [:]
        for window in snapshot.windows {
            for ws in window.tabManager.workspaces {
                for panel in ws.panels {
                    if let coord = panel.stableCoord {
                        map[coord] = panel.id
                    }
                }
            }
        }
        self.coordToPanelId = map
    }

    /// Look up the panel id that occupied `coord` in the snapshot. Returns `nil` if
    /// the snapshot was either unstamped or did not contain a panel at that
    /// coordinate.
    func panelId(at coord: StableLayoutCoord) -> UUID? {
        coordToPanelId[coord]
    }

    var coordCount: Int { coordToPanelId.count }
}
