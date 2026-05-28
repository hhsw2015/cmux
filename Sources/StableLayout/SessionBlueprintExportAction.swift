import AppKit
import Foundation

/// Bridges the Debug menu's `Export Session Blueprint to Pasteboard` button to
/// `SessionBlueprintEncoder`. Captures the current `AppSessionSnapshot`, renders
/// the markdown blueprint, and writes it to `NSPasteboard.general`.
///
/// Lives in DEBUG builds only — the underlying snapshot APIs are public, but
/// exposing this as a top-level menu action is for fork iteration and not a
/// supported user surface.
@MainActor
enum SessionBlueprintExportAction {
    static func copyCurrentBlueprintToPasteboard() {
        guard let snapshot = SessionPersistenceStore.load() else {
            NSSound.beep()
            return
        }
        let blueprint = SessionBlueprintEncoder.blueprint(from: snapshot)
        let text = SessionBlueprintEncoder.render(blueprint)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
