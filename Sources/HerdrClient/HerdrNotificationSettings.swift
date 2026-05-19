import Foundation

/// User-tunable knobs for herdr notifications. Persisted to
/// UserDefaults so they survive launches and can be toggled from
/// Settings -> Hosts.
enum HerdrNotificationSettings {
    static let blockedNotificationsEnabledKey = "cmux.herdr.notify.blocked.enabled"
    static let blockedNotificationsEnabledDefault = true

    static var blockedNotificationsEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: blockedNotificationsEnabledKey) == nil {
            return blockedNotificationsEnabledDefault
        }
        return defaults.bool(forKey: blockedNotificationsEnabledKey)
    }
}
