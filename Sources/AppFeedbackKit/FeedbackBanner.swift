import SwiftUI

/// A small banner that hosts can drop anywhere in their UI to invite feedback.
/// Tapping opens the same FeedbackSheet flow as the auto-presented sheet.
///
/// Visibility model — persistent across launches until acted on:
///   • Hidden until `launchCount >= minLaunchesBeforeAuto` AND server returns
///     eligible (project active, no audience-filter exclusion, no cooldown).
///   • Once visible, stays visible on every launch.
///   • Hidden permanently when the user completes the questionnaire
///     (`lastCompletedAt` is set).
///   • Hidden for 30 days when the user opens the sheet then closes it
///     without completing (`lastDismissedAt` triggers cooldown).
///   • Just ignoring the banner does NOT hide it — it'll keep appearing on
///     subsequent launches until the user takes one of the above actions.
public struct FeedbackBanner: View {

    public struct Style: Sendable {
        public var title: String
        public var subtitle: String
        public var systemImage: String
        public init(
            title: String = "Quick feedback?",
            subtitle: String = "Help us shape the next update — 2 minutes, anonymous.",
            systemImage: String = "quote.bubble.fill"
        ) {
            self.title = title
            self.subtitle = subtitle
            self.systemImage = systemImage
        }
    }

    let style: Style
    /// Force the banner to render regardless of eligibility — for dev/preview only.
    let previewAlways: Bool
    @State private var presented = false
    @State private var visible = false

    public init(style: Style = .init(), previewAlways: Bool = false) {
        self.style = style
        self.previewAlways = previewAlways
    }

    public var body: some View {
        Group {
            if visible || previewAlways {
                Button { presented = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: style.systemImage)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Color.accentColor)
                            .clipShape(.circle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(style.title).font(.subheadline.weight(.semibold))
                            Text(style.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.thinMaterial)
                    .clipShape(.rect(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.secondary.opacity(0.2), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            }
        }
        .task { await checkVisibility() }
        .sheet(isPresented: $presented, onDismiss: { Task { await checkVisibility() } }) {
            FeedbackSheet()
        }
    }

    private func checkVisibility() async {
        if previewAlways {
            visible = true
            return
        }
        visible = await AppFeedbackKit.shared.shouldPresent(.banner)
    }
}

public extension View {
    /// Adds a feedback banner above the receiver. Hidden automatically when
    /// the user isn't eligible.
    func feedbackBanner(style: FeedbackBanner.Style = .init()) -> some View {
        VStack(spacing: 0) {
            FeedbackBanner(style: style)
            self
        }
    }
}
