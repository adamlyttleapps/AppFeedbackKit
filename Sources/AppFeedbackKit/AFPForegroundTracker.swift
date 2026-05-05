import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Accumulates foreground time across launches into UserDefaults. Started
/// automatically by `AppFeedbackKit.configure(...)`, so the host app doesn't
/// need to think about it. Reports two metrics:
///   • `totalForegroundSeconds` — cumulative since install (persisted)
///   • `currentSessionForegroundSeconds` — since the most recent foreground
///     entry (volatile)
///
/// Strategy:
///   1. On launch (configure call), if app is already active, start a session.
///   2. Listen for foreground/background notifications and bracket sessions.
///   3. While in foreground, flush every 30s to UserDefaults so a force-kill
///      doesn't lose the session.
@MainActor
final class AFPForegroundTracker {

    static let shared = AFPForegroundTracker()

    private let storage: AFPStorage
    private var sessionStart: Date?
    private var backgroundedAt: Date?
    private var flushTimer: Timer?
    private var started = false

    init(storage: AFPStorage = AppFeedbackKit.shared.storage) {
        self.storage = storage
    }

    /// Idempotent — safe to call from configure() and from the modifier.
    func start() {
        guard !started else { return }
        started = true

        #if canImport(UIKit)
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didEnterForeground),
                       name: UIApplication.willEnterForegroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(didEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        // First-launch case: app just became active, no foreground notification fires.
        if UIApplication.shared.applicationState == .active {
            beginSession()
        }
        #endif
    }

    /// Seconds in foreground for the *current* session, or 0 if backgrounded.
    var currentSessionForegroundSeconds: Double {
        guard let s = sessionStart else { return 0 }
        return Date().timeIntervalSince(s)
    }

    /// Cumulative across all sessions, including the live one.
    var totalForegroundSeconds: Double {
        storage.totalForegroundSeconds + currentSessionForegroundSeconds
    }

    // MARK: - Lifecycle

    @objc private func didEnterForeground() {
        // If the app was backgrounded for longer than the configured
        // session-expiry threshold, count this re-entry as a fresh launch.
        if let bgAt = backgroundedAt {
            let threshold = AppFeedbackKit.shared.config?.relaunchAfterBackgroundSeconds ?? (30 * 60)
            if Date().timeIntervalSince(bgAt) >= threshold {
                storage.recordLaunch()
            }
        }
        backgroundedAt = nil
        beginSession()
    }

    @objc private func didEnterBackground() {
        flush()
        sessionStart = nil
        flushTimer?.invalidate()
        flushTimer = nil
        backgroundedAt = Date()
    }

    private func beginSession() {
        guard sessionStart == nil else { return }
        sessionStart = Date()
        // 30s flush cadence — survives a force-kill that skips
        // didEnterBackgroundNotification.
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
    }

    /// Move accumulated session time into persistent storage and re-anchor
    /// the session clock to now. Idempotent.
    private func flush() {
        guard let s = sessionStart else { return }
        let elapsed = Date().timeIntervalSince(s)
        if elapsed > 0 {
            storage.totalForegroundSeconds += elapsed
            sessionStart = Date()
        }
    }
}
