import Foundation
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

/// Gathers passive device + subscription context with NO permission prompts.
///
/// Everything here is either a system-framework property (no consent needed)
/// or StoreKit 2 entitlements (the host app's own purchases — no prompt).
///
/// Notably *not* gathered: IDFA (would need ATT prompt), location, contacts,
/// device name (often contains the user's real name, privacy hazard).
enum AFPDeviceProbe {

    // ---------- Sync probe (cheap properties, suitable for every request) ----

    /// `@MainActor` because we read UIScreen / UIApplication / the foreground
    /// tracker, all of which are MainActor-isolated. Marking this here means
    /// the SDK works in host apps regardless of their default-actor-isolation
    /// build setting.
    @MainActor
    static func snapshot(launches: Int, firstLaunch: Date?) -> [String: AFPJSONOut] {
        var out: [String: AFPJSONOut] = [:]

        let bundle = Bundle.main
        out["app_version"]  = .string((bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "")
        out["app_build"]    = .string((bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "")
        out["bundle_id"]    = .string(bundle.bundleIdentifier ?? "")

        out["os_version"]   = .string(systemVersion())
        out["device_class"] = .string(deviceClass())
        out["device_model"] = .string(deviceModelIdentifier())

        out["locale"]               = .string(Locale.current.identifier)
        out["region"]               = .string(Locale.current.region?.identifier ?? "")
        out["preferred_languages"]  = .array(Locale.preferredLanguages.prefix(3).map(AFPJSONOut.string))
        out["timezone"]             = .string(TimeZone.current.identifier)

        out["sessions"]      = .int(launches)
        if let first = firstLaunch {
            out["first_launch_at"]   = .string(ISO8601DateFormatter().string(from: first))
            out["days_since_install"] = .int(max(0, Int(Date().timeIntervalSince(first) / 86400)))
        }

        // Foreground-time signal: how engaged is this user really? Cumulative
        // since install + how long they've been actively using the app right
        // now. Distinguishes "opened twice and never came back" vs "in here
        // every day for an hour".
        let tracker = AFPForegroundTracker.shared
        out["total_foreground_seconds"]           = .int(Int(tracker.totalForegroundSeconds))
        out["current_session_foreground_seconds"] = .int(Int(tracker.currentSessionForegroundSeconds))

        let mem = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
        out["physical_memory_mb"] = .int(mem)
        out["low_power_mode"]     = .bool(ProcessInfo.processInfo.isLowPowerModeEnabled)
        out["thermal_state"]      = .string(thermalStateString())

        if let bytes = freeDiskBytes() {
            out["free_disk_mb"] = .int(Int(bytes / 1_048_576))
        }

        #if canImport(UIKit)
        let screen = UIScreen.main
        let bounds = screen.bounds
        out["screen_size"]    = .string("\(Int(bounds.width))x\(Int(bounds.height))")
        out["screen_scale"]   = .double(Double(screen.scale))
        out["dark_mode"]      = .bool(screen.traitCollection.userInterfaceStyle == .dark)
        out["dynamic_type"]   = .string(dynamicTypeString())
        out["voice_over"]     = .bool(UIAccessibility.isVoiceOverRunning)
        out["reduce_motion"]  = .bool(UIAccessibility.isReduceMotionEnabled)
        #endif

        return out
    }

    // ---------- Async probe — StoreKit 2 active entitlements ----------------
    //
    // Wraps Transaction.currentEntitlements with a hard timeout so it can't
    // block the questionnaire flow if StoreKit is unresponsive. Returns []
    // if the app has no IAP configured or the call times out.

    static func subscriptions(timeout: TimeInterval = 1.5) async -> [AFPJSONOut] {
        await withTaskGroup(of: [AFPJSONOut].self) { group in
            group.addTask {
                var found: [AFPJSONOut] = []
                let iso = ISO8601DateFormatter()
                for await result in Transaction.currentEntitlements {
                    guard case .verified(let t) = result else { continue }
                    var entry: [String: AFPJSONOut] = [
                        "product_id":   .string(t.productID),
                        "purchase_date": .string(iso.string(from: t.purchaseDate)),
                        "is_active":    .bool(t.revocationDate == nil),
                    ]
                    if let exp = t.expirationDate {
                        entry["expires_at"] = .string(iso.string(from: exp))
                    }
                    if let revoked = t.revocationDate {
                        entry["revoked_at"] = .string(iso.string(from: revoked))
                    }
                    entry["is_upgraded"]   = .bool(t.isUpgraded)
                    entry["product_type"]  = .string(String(describing: t.productType))
                    found.append(.object(entry))
                }
                return found
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return []
            }
            // Take whichever finishes first; subsequent results are ignored.
            for await first in group {
                group.cancelAll()
                return first
            }
            return []
        }
    }

    // ---------- Helpers ----------

    private static func systemVersion() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    private static func deviceClass() -> String {
        #if canImport(UIKit)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: return "iPhone"
        case .pad:   return "iPad"
        case .tv:    return "AppleTV"
        case .mac:   return "Mac"
        case .vision: return "VisionPro"
        default:     return "Unknown"
        }
        #else
        return "Unknown"
        #endif
    }

    /// Hardware identifier like "iPhone15,3" via uname(2) — Apple's official
    /// public way to identify the model class without permission.
    private static func deviceModelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        let id = withUnsafePointer(to: &info.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
        return id
    }

    private static func freeDiskBytes() -> Int64? {
        guard let url = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else {
            return nil
        }
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else {
            return nil
        }
        return values.volumeAvailableCapacityForImportantUsage
    }

    private static func thermalStateString() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    #if canImport(UIKit)
    private static func dynamicTypeString() -> String {
        switch UIApplication.shared.preferredContentSizeCategory {
        case .extraSmall:                       return "XS"
        case .small:                            return "S"
        case .medium:                           return "M"
        case .large:                            return "L"
        case .extraLarge:                       return "XL"
        case .extraExtraLarge:                  return "XXL"
        case .extraExtraExtraLarge:             return "XXXL"
        case .accessibilityMedium:              return "AX-M"
        case .accessibilityLarge:               return "AX-L"
        case .accessibilityExtraLarge:          return "AX-XL"
        case .accessibilityExtraExtraLarge:     return "AX-XXL"
        case .accessibilityExtraExtraExtraLarge: return "AX-XXXL"
        default:                                return "L"
        }
    }
    #endif
}
