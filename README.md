# AppFeedbackKit

Drop-in SwiftUI feedback SDK for indie iOS apps. Asks your users persona-defining questions inside your app and turns the answers into ranked personas + ready-to-paste Meta ad copy on the [AppFeedbackKit dashboard](https://app.appfeedbackkit.com).

- Zero third-party dependencies — URLSession + Codable + SwiftUI + StoreKit + WebKit, all system frameworks.
- No ATT prompt. No IDFA. No location, contacts, or photos. No cross-app tracking.
- Privacy manifest (`PrivacyInfo.xcprivacy`) bundled — merges into your host app at build time.
- Forward-compatible client: server-side question types your shipped client doesn't recognise are silently skipped, so the dashboard can ship new question kinds without forcing you to update your app.
- iOS 17+.

## Install

Xcode → File → Add Package Dependencies… and paste:

```
https://github.com/adamlyttleapps/AppFeedbackKit.git
```

Or in your `Package.swift`:

```swift
.package(url: "https://github.com/adamlyttleapps/AppFeedbackKit.git", from: "1.0.0"),
```

## Get your API keys

Sign up at [app.appfeedbackkit.com](https://app.appfeedbackkit.com), create a project (paste your App Store URL — questions, features, and screenshots auto-generate), and copy the `apiKey` + `apiSecret` from the project page.

## Use

### 1. Configure once at app launch

```swift
import SwiftUI
import AppFeedbackKit

@main
struct YourApp: App {
    init() {
        AppFeedbackKit.configure(.init(
            apiKey:    "afk_...",
            apiSecret: "..."
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .appFeedbackSheet()   // auto-presents after 3 launches + server eligibility
        }
    }
}
```

### 2. (Optional) Manual triggering

The default `.appFeedbackSheet()` modifier auto-presents based on the server's eligibility check. If you also want a "Send feedback" button somewhere in your app, bind a `@State` Bool:

```swift
@State var showFeedback = false

Button("Send feedback") { showFeedback = true }

ContentView().appFeedbackSheet(isPresented: $showFeedback)
```

## How it behaves

| Behaviour                | Default                              | Override                                                                 |
| ------------------------ | ------------------------------------ | ------------------------------------------------------------------------ |
| Min launches before auto-sheet | 3                              | `Config(minLaunchesBeforeAuto:)`                                         |
| Background → foreground counts as a new launch | After 30 min away    | `Config(relaunchAfterBackgroundSeconds:)` — set 0 to count every foreground |
| Cooldown after dismiss / complete | 30 days (server-enforced too) | Server-controlled per project; the SDK respects it locally too.          |
| Persistence              | UserDefaults (resets on reinstall)   | Intentional — a fresh install is a fresh user.                           |
| Identity                 | Opaque UUID generated client-side    | Anonymous by design. No PII unless you explicitly enable contact opt-in. |

## Apple App Store privacy compliance

The SDK ships a `PrivacyInfo.xcprivacy` manifest at `Sources/AppFeedbackKit/PrivacyInfo.xcprivacy`. Xcode merges it with your host app's manifest at build time. Host apps embedding AppFeedbackKit MUST also do the following before submitting to the App Store:

### 1. Ship your own `PrivacyInfo.xcprivacy`

Even with the SDK manifest, your app needs its own (declaring any APIs your code uses). The SDK's manifest will merge in automatically.

### 2. Update App Store Connect → App Privacy → Privacy Nutrition Label

Declare these data types AppFeedbackKit collects (all "Not Linked to User", "Not Used for Tracking"):

| Data type             | Purpose                                                |
| --------------------- | ------------------------------------------------------ |
| Other User Content    | App Functionality, Analytics, Product Personalization  |
| Other Diagnostic Data | Analytics, App Functionality                           |
| Purchase History      | Analytics, Product Personalization                     |
| Product Interaction   | Analytics, Product Personalization                     |

If you enable the **Contact opt-in** question type (off by default), also declare:

| Data type     | Linkage         | Purpose          |
| ------------- | --------------- | ---------------- |
| Email Address | Linked to User  | App Functionality |

### 3. Add a paragraph to your privacy policy

Suggested wording, copy-pasteable:

> *We use AppFeedbackKit to collect anonymous in-app feedback. When you respond to the questionnaire we transmit your answers, free-text responses, app version, device model, OS version, locale, time spent in the app, launch count, and any active subscriptions you have purchased through the App Store. An opaque random identifier (UUID) is generated on your device to deduplicate responses; it is stored only in this app's local preferences and resets if you reinstall. We do not collect your name, email \[unless you explicitly opt in\], device advertising identifier (IDFA), location, contacts, or any data from outside this app. We do not track you across apps or websites.*

### 4. Don't ship in Kids-Category apps without extra work

Apple's Kids Category requires parental-consent infrastructure. AppFeedbackKit doesn't include any. Don't drop it into a Kids app without first wiring up a COPPA-compliant consent gate.

### 5. What's deliberately NOT collected (so you don't have to declare these)

- IDFA / device advertising identifier (would require ATT prompt — we never request)
- Location, contacts, calendar, photos, microphone, camera (no permissions touched)
- Persistent identity that survives reinstall (UUID intentionally lives in `UserDefaults`, not Keychain)
- Cross-app or cross-website tracking signals
- Apple-proprietary StoreKit data beyond entitlement product IDs + dates

## What gets sent over the wire

Every request to the AppFeedbackKit backend is signed with your `apiSecret` — the secret never leaves the device on the wire. Each request body includes:

- **Device context** (passive, no permissions): app version, build, bundle id, OS version, device class + model, locale + region + preferred languages, timezone, screen size, physical memory, free disk, accessibility flags (Dark Mode, Dynamic Type, VoiceOver, Reduce Motion), low-power and thermal state.
- **Engagement**: opaque device UUID, launch count, first-launch date, days since install, total foreground seconds, current-session foreground seconds.
- **Active StoreKit entitlements**: product IDs, dates, active flag — your own first-party purchase data.
- **Questionnaire answers** (only when the user actually answers a question).

## Pricing

- **Indie devs:** free. No project cap, no response cap, no paywall.
- **Companies / commercial use:** [hello@appfeedbackkit.com](mailto:hello@appfeedbackkit.com) for licensing.

## License

MIT — see [LICENSE](LICENSE). The SwiftUI client is open source. The hosted dashboard backend is a separately operated, closed-source service.
