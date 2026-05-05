import SwiftUI

public extension View {

    /// Auto-presents the feedback sheet on app launch when the user is eligible.
    /// Only fires once per launch, after a small delay so it doesn't fight your
    /// app's own onboarding/splash.
    func appFeedbackSheet(autoPresent: Bool = true) -> some View {
        modifier(AppFeedbackSheetModifier(autoPresent: autoPresent))
    }

    /// Manually-controlled sheet — bind to your own @State.
    func appFeedbackSheet(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) { FeedbackSheet() }
    }
}

private struct AppFeedbackSheetModifier: ViewModifier {
    let autoPresent: Bool
    @State private var presented = false
    @State private var didCheck = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $presented) { FeedbackSheet() }
            .onReceive(NotificationCenter.default.publisher(for: AppFeedbackKit.presentRequested)) { _ in
                presented = true
            }
            .task {
                guard autoPresent, !didCheck else { return }
                didCheck = true
                // 1.2s grace so the sheet doesn't slam down on cold launch.
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if await AppFeedbackKit.shared.shouldPresent(.sheet) {
                    presented = true
                }
            }
    }
}
