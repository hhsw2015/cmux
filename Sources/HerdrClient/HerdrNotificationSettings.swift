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

    static let hostOfflineNotificationsEnabledKey = "cmux.herdr.notify.hostOffline.enabled"
    static let hostOfflineNotificationsEnabledDefault = true

    /// Whether a macOS notification fires when a remote herdr daemon
    /// stays in retrying state past the offline threshold. Defaults
    /// on so dogfood users notice silent disconnects.
    static var hostOfflineNotificationsEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: hostOfflineNotificationsEnabledKey) == nil {
            return hostOfflineNotificationsEnabledDefault
        }
        return defaults.bool(forKey: hostOfflineNotificationsEnabledKey)
    }

    /// Threshold (seconds) before a sustained retry triggers the
    /// host-offline notification. Short blips (network bounce, ssh
    /// control master refresh) shouldn't notify.
    static let hostOfflineNotificationDelaySeconds: TimeInterval = 20
}
