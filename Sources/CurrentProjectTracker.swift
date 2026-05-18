import Foundation

/// Remembers which project the user opened so cmux can auto-save the
/// updated layout on quit. Off-disk: persists to `UserDefaults` so a
/// crash mid-session still recovers the last-known project name.
@MainActor
enum CurrentProjectTracker {
    private static let key = "session.persistence.currentProject"

    static var name: String? {
        get {
            let raw = UserDefaults.standard.string(forKey: key)
            return (raw?.isEmpty ?? true) ? nil : raw
        }
        set {
            if let value = newValue, !value.isEmpty {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
