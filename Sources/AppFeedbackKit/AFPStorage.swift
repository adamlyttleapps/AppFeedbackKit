import Foundation

/// Persistence in UserDefaults (intentionally not Keychain — reinstalling the
/// host app should reset cooldowns by design).
final class AFPStorage: @unchecked Sendable {

    private enum Key {
        static let deviceId               = "afp.device_id"
        static let launchCount            = "afp.launch_count"
        static let lastDismissedAt        = "afp.last_dismissed_at"
        static let lastCompletedAt        = "afp.last_completed_at"
        static let firstLaunchAt          = "afp.first_launch_at"
        static let totalForegroundSeconds = "afp.total_foreground_seconds"
    }

    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var deviceId: String {
        if let existing = defaults.string(forKey: Key.deviceId) {
            return existing
        }
        let new = UUID().uuidString
        defaults.set(new, forKey: Key.deviceId)
        return new
    }

    var launchCount: Int {
        get { defaults.integer(forKey: Key.launchCount) }
        set { defaults.set(newValue, forKey: Key.launchCount) }
    }

    var lastDismissedAt: Date? {
        get { defaults.object(forKey: Key.lastDismissedAt) as? Date }
        set { defaults.set(newValue, forKey: Key.lastDismissedAt) }
    }

    var lastCompletedAt: Date? {
        get { defaults.object(forKey: Key.lastCompletedAt) as? Date }
        set { defaults.set(newValue, forKey: Key.lastCompletedAt) }
    }

    /// Set once on first launch; intentionally cleared on `reset()` and on
    /// app reinstall (we use UserDefaults, not Keychain — by design).
    var firstLaunchAt: Date? {
        get { defaults.object(forKey: Key.firstLaunchAt) as? Date }
        set { defaults.set(newValue, forKey: Key.firstLaunchAt) }
    }

    /// Cumulative seconds the host app has been in the foreground since
    /// install. Driven by AFPForegroundTracker; reset on uninstall.
    var totalForegroundSeconds: Double {
        get { defaults.double(forKey: Key.totalForegroundSeconds) }
        set { defaults.set(newValue, forKey: Key.totalForegroundSeconds) }
    }

    func recordLaunch() {
        if firstLaunchAt == nil { firstLaunchAt = Date() }
        launchCount += 1
    }

    func recordDismissed() {
        lastDismissedAt = Date()
    }

    func recordCompleted() {
        lastCompletedAt = Date()
    }

    func reset() {
        defaults.removeObject(forKey: Key.deviceId)
        defaults.removeObject(forKey: Key.launchCount)
        defaults.removeObject(forKey: Key.lastDismissedAt)
        defaults.removeObject(forKey: Key.lastCompletedAt)
        defaults.removeObject(forKey: Key.firstLaunchAt)
        defaults.removeObject(forKey: Key.totalForegroundSeconds)
    }
}
