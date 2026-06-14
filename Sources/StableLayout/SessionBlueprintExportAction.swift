import AppKit
import Foundation

/// Debug-menu hook for exporting the current `AppSessionSnapshot` as a
/// markdown blueprint. ponytail: parked while upstream finishes the
/// `SessionPersistenceStore -> SessionSnapshotRepository` migration.
@MainActor
enum SessionBlueprintExportAction {
    static func copyCurrentBlueprintToPasteboard() {
        NSSound.beep()
    }
}
