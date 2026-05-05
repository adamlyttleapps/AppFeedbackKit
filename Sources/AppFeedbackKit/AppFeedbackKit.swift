import Foundation
import SwiftUI

/// AppFeedbackKit — drop-in client SDK for the App Feedback Playground service.
///
/// Usage in the host app:
///
///     @main
///     struct MyApp: App {
///         init() {
///             AppFeedbackKit.configure(
///                 apiKey: "afp_...",
///                 apiSecret: "..."
///             )
///         }
///         var body: some Scene {
///             WindowGroup {
///                 ContentView()
///                     .appFeedbackSheet()
///             }
///         }
///     }
///
/// Which surface the host project has enabled for showing the questionnaire.
/// Server-controlled — `/api/eligibility` returns the current mode on every
/// check, so flipping it in the dashboard takes effect on the next user open.
public enum AFPSurface: String, Sendable {
    case sheet
    case banner
}

/// Zero third-party dependencies — URLSession + Codable + SwiftUI only.
@MainActor
public final class AppFeedbackKit {

    public static let shared = AppFeedbackKit()

    public struct Config: Sendable {
        public var apiKey: String
        public var apiSecret: String
        public var minLaunchesBeforeAuto: Int
        /// If the app is backgrounded for at least this long, the next
        /// foreground entry counts as a fresh launch (increments launchCount).
        /// Matches the industry-standard 30-minute session-expiry rule
        /// (Google Analytics, Firebase, Mixpanel default). Set to 0 to count
        /// every foreground as a launch; set very high to count only cold
        /// launches.
        public var relaunchAfterBackgroundSeconds: TimeInterval

        public init(
            apiKey: String,
            apiSecret: String,
            minLaunchesBeforeAuto: Int = 3,
            relaunchAfterBackgroundSeconds: TimeInterval = 30 * 60
        ) {
            self.apiKey = apiKey
            self.apiSecret = apiSecret
            self.minLaunchesBeforeAuto = minLaunchesBeforeAuto
            self.relaunchAfterBackgroundSeconds = relaunchAfterBackgroundSeconds
        }
    }

    /// The backend URL the SDK talks to. Hardcoded to production so indie
    /// devs consuming this Swift Package don't need to think about it.
    /// Use `_setDevBaseURL(_:)` from a `#if DEBUG` block if you maintain
    /// the SDK and need to point at a local server.
    static let productionBaseURL = URL(string: "https://api.appfeedbackkit.com")!
    private(set) var baseURL: URL = productionBaseURL

    /// Internal escape hatch for SDK maintainers to point at a local backend
    /// during development. The leading underscore + the explicit name signal
    /// "this is not part of the public package API". Call BEFORE `configure`.
    public static func _setDevBaseURL(_ url: URL) {
        shared.baseURL = url
    }

    private(set) var config: Config?
    let storage = AFPStorage()
    private(set) lazy var client: AFPClient = AFPClient(kit: self)

    private init() {}

    /// Call once at app launch (e.g. in `App.init()`).
    public static func configure(apiKey: String, apiSecret: String) {
        configure(.init(apiKey: apiKey, apiSecret: apiSecret))
    }

    public static func configure(_ config: Config) {
        shared.config = config
        shared.storage.recordLaunch()
        AFPForegroundTracker.shared.start()
    }

    /// Increment the launch counter manually (for hosts that want to bump it
    /// on screen visit rather than app launch).
    public static func recordLaunch() {
        shared.storage.recordLaunch()
    }

    /// Quick local check: did the user dismiss/complete recently? Avoids the
    /// network round-trip when we already know the answer is "not yet".
    public var localCooldownActive: Bool {
        if let dismissed = storage.lastDismissedAt {
            if Date().timeIntervalSince(dismissed) < AFPCooldown.seconds { return true }
        }
        if storage.lastCompletedAt != nil { return true }
        return false
    }

    /// Server-authoritative eligibility check. Always do this before presenting.
    /// `surface` defaults to .sheet for back-compat with existing call sites.
    /// Pass .banner from the FeedbackBanner so it can hide itself when the
    /// project is in "sheet only" mode (and vice versa).
    ///
    /// We always hit /api/eligibility (rather than short-circuiting on local
    /// state) so the project's `debug_mode` flag can override local cooldowns
    /// when the SDK author needs to test the flow on a device that's already
    /// completed/dismissed.
    public func shouldPresent(_ surface: AFPSurface = .sheet) async -> Bool {
        guard config != nil else { return false }
        do {
            let resp: AFPEligibilityResponse = try await client.post(
                path: "/api/eligibility",
                body: AFPDeviceContext.current(launches: storage.launchCount)
            )
            let bypass = resp.bypass_cooldown ?? false
            if !bypass {
                if localCooldownActive { return false }
                if storage.launchCount < (config?.minLaunchesBeforeAuto ?? 3) { return false }
            }
            guard resp.eligible else { return false }
            return Self.modeAllows(surface, mode: resp.presentation_mode)
        } catch {
            return false
        }
    }

    static func modeAllows(_ surface: AFPSurface, mode: String?) -> Bool {
        switch (mode ?? "both") {
        case "both":   return true
        case "sheet":  return surface == .sheet
        case "banner": return surface == .banner
        default:       return true   // unknown server value — don't suppress
        }
    }

    /// Programmatically open the sheet (e.g. from a "Send feedback" button).
    /// View modifiers attached via `.appFeedbackSheet()` listen for this and
    /// raise the sheet.
    public func present() {
        NotificationCenter.default.post(name: AppFeedbackKit.presentRequested, object: nil)
    }

    static let presentRequested = Notification.Name("com.appfeedbackkit.AppFeedbackKit.presentRequested")

    /// Reset all stored state — useful for development. Don't call from prod.
    /// Re-records the current launch afterwards so launchCount reflects the
    /// session you're in (otherwise it reads 0 until next cold start, which
    /// is confusing during dev).
    public func resetForDevelopment() {
        storage.reset()
        storage.recordLaunch()
    }
}

enum AFPCooldown {
    static let days: Int = 30
    static var seconds: TimeInterval { TimeInterval(days * 86_400) }
}
