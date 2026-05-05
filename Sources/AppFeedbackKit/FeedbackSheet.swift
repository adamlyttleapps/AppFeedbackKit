import SwiftUI
import WebKit

/// The sheet that hosts the entire questionnaire flow.
public struct FeedbackSheet: View {

    @StateObject private var state = AFPState()
    @Environment(\.dismiss) private var dismissEnv

    public init() {}

    public var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") {
                            Task { await state.dismiss(); dismissEnv() }
                        }
                    }
                }
        }
        .task { await state.load() }
        .interactiveDismissDisabled(state.phase != .completed)
    }

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .loading:
            ProgressView().controlSize(.large)
        case .empty:
            CenteredMessage(title: "All caught up", subtitle: "Nothing to ask right now.")
                .onAppear { Task { await state.dismiss(); dismissEnv() } }
        case .error(let msg):
            CenteredMessage(title: "Couldn't load", subtitle: msg)
        case .completed:
            CenteredMessage(title: "Thanks ", subtitle: "Your feedback helps a lot.")
                .toolbar(.hidden, for: .navigationBar)
                .task {
                    try? await Task.sleep(nanoseconds: 1_300_000_000)
                    dismissEnv()
                }
        case .ready:
            VStack(spacing: 0) {
                ProgressView(value: state.progress)
                    .padding(.horizontal)
                    .padding(.top, 8)
                stepView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var stepView: some View {
        if let q = state.currentQuestion {
            // Renderer registry: known types render inline, unknown types log + advance.
            switch q.type {
            case "welcome":              WelcomeStep(question: q, state: state)
            case "sean_ellis":           SeanEllisStep(question: q, state: state)
            case "nps":                  NPSStep(question: q, state: state)
            case "single_choice":        SingleChoiceStep(question: q, state: state)
            case "multi_choice":         MultiChoiceStep(question: q, state: state)
            case "feature_priorities":   FeaturePrioritiesStep(question: q, state: state)
            case "screenshot_pairwise":  ScreenshotPairwiseStep(question: q, state: state)
            case "free_text":            FreeTextStep(question: q, state: state)
            case "wtp":                  WTPStep(question: q, state: state)
            case "acquisition":          SingleChoiceStep(question: q, state: state)
            case "jobs_to_be_done":      SingleChoiceStep(question: q, state: state)
            case "self_identification":  ChoiceWithOtherStep(question: q, state: state)
            case "trigger":              ChoiceWithOtherStep(question: q, state: state)
            case "alternatives":         ChoiceWithOtherStep(question: q, state: state)
            case "transformation":       FreeTextStep(question: q, state: state)
            case "emotional_adjectives": EmotionalAdjectivesStep(question: q, state: state)
            case "demographics":         DemographicsStep(question: q, state: state)
            case "anything_else":        FreeTextStep(question: q, state: state)
            case "contact_optin":        ContactOptInStep(question: q, state: state)
            default:
                // Forward-compat: server added a question type the shipped
                // client doesn't know about. Skip it (and log telemetry) so
                // the user keeps moving. `.task(id:)` keys on q.id so this
                // re-fires for every consecutive unknown question.
                ProgressView()
                    .task(id: q.id) { await state.skipUnknown(type: q.type, questionId: q.id) }
            }
        } else {
            ProgressView()
        }
    }
}

// ============================================================
// Step shell — common header (prompt + hint) + footer (Skip / Continue)
// ============================================================

private struct StepShell<Content: View>: View {
    let question: AFPQuestion
    let state: AFPState
    let canContinue: Bool
    let onContinue: () -> Void
    @ViewBuilder var content: () -> Content

    init(
        question: AFPQuestion,
        state: AFPState,
        canContinue: Bool = true,
        onContinue: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.question = question
        self.state = state
        self.canContinue = canContinue
        self.onContinue = onContinue
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let prompt = question.prompt, !prompt.isEmpty {
                        Text(prompt)
                            .font(.title2.weight(.semibold))
                    }
                    if let hint = question.hint, !hint.isEmpty {
                        Text(hint)
                            .foregroundStyle(.secondary)
                    }
                    Spacer().frame(height: 8)
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            footer
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if !question.required {
                Button("Skip") {
                    Task { await state.submitAnswer(.null, skipped: true) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onContinue) {
                Text("Continue")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(canContinue ? Color.accentColor : Color.secondary.opacity(0.4))
                    .foregroundStyle(.white)
                    .clipShape(.capsule)
            }
            .disabled(!canContinue)
        }
        .padding()
        .background(.bar)
    }
}

// ============================================================
// Step views
// ============================================================

private struct WelcomeStep: View {
    let question: AFPQuestion
    @ObservedObject var state: AFPState
    var body: some View {
        let videoURL = question.config.video_url.stringValue ?? ""
        let parsed = AFPYouTube.parse(videoURL)
        StepShell(question: question, state: state, canContinue: true,
                  onContinue: { Task { await state.submitAnswer(.null) } }) {
            VStack(alignment: .leading, spacing: 12) {
                if let parsed {
                    AFPYouTubePlayer(videoID: parsed.id)
                        .aspectRatio(parsed.isShort ? 9/16 : 16/9, contentMode: .fit)
                        .frame(maxWidth: parsed.isShort ? 320 : .infinity)
                        .frame(maxWidth: .infinity)
                        .clipShape(.rect(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.2), lineWidth: 1))
                }
            }
        }
    }
}

/// Lightweight WKWebView wrapper that loads a YouTube embed via an HTML
/// wrapper page (loading the embed URL directly hits YouTube error 153 —
/// the player wants a real document origin).
private struct AFPYouTubePlayer: UIViewRepresentable {
    let videoID: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.backgroundColor = .black
        webView.isOpaque = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let html = """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
        <style>html,body{margin:0;padding:0;background:#000;height:100%;}iframe{border:0;width:100%;height:100%;}</style>
        </head><body>
        <iframe src="https://www.youtube-nocookie.com/embed/\(videoID)?playsinline=1&modestbranding=1&rel=0"
                allow="accelerometer; autoplay; encrypted-media; gyroscope; picture-in-picture; fullscreen"
                allowfullscreen></iframe>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com"))
    }
}

enum AFPYouTube {
    struct Parsed {
        let id: String
        let isShort: Bool
    }

    /// Pull the video id (and short-ness) out of any common YouTube URL shape:
    ///   https://youtu.be/<id>
    ///   https://www.youtube.com/watch?v=<id>
    ///   https://www.youtube.com/embed/<id>
    ///   https://www.youtube.com/shorts/<id>   ← isShort = true (9:16 aspect)
    /// Returns nil for non-YouTube or unparseable input.
    static func parse(_ raw: String) -> Parsed? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let comps = URLComponents(string: trimmed) else { return nil }
        let host = (comps.host ?? "").lowercased()

        if host.contains("youtu.be") {
            if let id = idIfValid(String(comps.path.dropFirst())) {
                return Parsed(id: id, isShort: false)
            }
            return nil
        }
        if host.contains("youtube.com") {
            if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, let id = idIfValid(v) {
                return Parsed(id: id, isShort: false)
            }
            let parts = comps.path.split(separator: "/").map(String.init)
            if let i = parts.firstIndex(where: { $0 == "embed" || $0 == "shorts" || $0 == "v" }), i + 1 < parts.count,
               let id = idIfValid(parts[i + 1]) {
                return Parsed(id: id, isShort: parts[i] == "shorts")
            }
        }
        return nil
    }

    /// Back-compat string-only entry point.
    static func extractID(from raw: String) -> String? { parse(raw)?.id }

    private static func idIfValid(_ s: String) -> String? {
        // YouTube ids are 11 chars, alphanumeric + - and _.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard s.count == 11, s.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return s
    }
}

private struct SeanEllisStep: View {
    let question: AFPQuestion
    @ObservedObject var state: AFPState
    @State private var pick: String?
    private let options: [(String, String)] = [
        ("very",     "Very disappointed"),
        ("somewhat", "Somewhat disappointed"),
        ("not",      "Not disappointed"),
        ("na",       "I don't really use it"),
    ]
    var body: some View {
        StepShell(question: question, state: state, canContinue: pick != nil,
                  onContinue: { Task { await state.submitAnswer(.object(["choice": .string(pick ?? "")])) } }) {
            VStack(spacing: 8) {
                ForEach(options, id: \.0) { opt in
                    ChoiceRow(label: opt.1, selected: pick == opt.0) { pick = opt.0 }
                }
            }
        }
    }
}

private struct NPSStep: View {
    let question: AFPQuestion
    @ObservedObject var state: AFPState
    @State private var score: Int?
    var body: some View {
        StepShell(question: question, state: state, canContinue: score != nil,
                  onContinue: { Task { await state.submitAnswer(.object(["score": .int(score ?? 0)])) } }) {
            VStack(spacing: 8) {
                LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 6), spacing: 8) {
                    ForEach(0...10, id: \.self) { n in
                        Button { score = n } label: {
                            Text("\(n)")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(score == n ? Color.accentColor : Color.secondary.opacity(0.15))
                                .foregroundStyle(score == n ? .white : .primary)
                                .clipShape(.rect(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    Text("Not likely").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("Very likely").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct SingleChoiceStep: View {
    let question: AFPQuestion
    @ObservedObject var state: AFPState
    @State private var pick: String?
    var body: some View {
        let options = question.config.options.stringArray
        StepShell(question: question, state: state, canContinue: pick != nil,
                  onContinue: { Task { await state.submitAnswer(.object(["choice": .string(pick ?? "")])) } }) {
            VStack(spacing: 8) {
                ForEach(options, id: \.self) { opt in
                    ChoiceRow(label: opt, selected: pick == opt) { pick = opt }
                }
            }
        }
    }
}

private struct MultiChoiceStep: View {
    let question: AFPQuestion
    @ObservedObject var state: AFPState
    @State private var picks: Set<String> = []
    var body: some View {
        let options = question.config.options.stringArray
        let maxPick = question.config.max_pick.intValue ?? 0
        StepShell(question: question, state: state, canContinue: !picks.isEmpty,
                  onContinue: {
                      let arr = Array(picks).map(AFPJSONOut.string)
                      Task { await state.submitAnswer(.object(["choices": .array(arr)])) }
                  }) {
            VStack(spacing: 8) {
                ForEach(options, id: \.self) { opt in
                    ChoiceRow(label: opt, selected: picks.contains(opt), multi: true) {
                        if picks.contains(opt) {
                            picks.remove(opt)
                        } else {
                            if maxPick > 0 && picks.count >= maxPick { return }
                            picks.insert(opt)
                        }
                    }
                }
            }
        }
    }
}

private struct FeaturePrioritiesStep: View {
    let question: AFPQuestion
    @ObservedObject var state: AFPState
    @State private var picks: Set<Int> = []

    private struct Feature: Identifiable, Hashable {
        let id: Int
        let label: String
    }

    private var features: [Feature] {
        question.config.features.arrayValue.compactMap { item in
            guard let id = item.id.intValue, let label = item.label.stringValue else { return nil }
            return Feature(id: id, label: label)
        }
    }

    var body: some View {
        let maxPick = question.config.max_pick.intValue ?? 3
        StepShell(question: question, state: state, canContinue: !picks.isEmpty,
                  onContinue: {
                      let arr = picks.sorted().map { AFPJSONOut.int($0) }
                      Task { await state.submitAnswer(.object(["choices": .array(arr)])) }
                  }) {
            VStack(spacing: 8) {
                ForEach(features) { f in
                    ChoiceRow(label: f.label, selected: picks.contains(f.id), multi: true) {
                        if picks.contains(f.id) {
                            picks.remove(f.id)
                        } else {
                            if maxPick > 0 && picks.count >= maxPick { return }
                            picks.insert(f.id)
                        }
                    }
                }
                if features.isEmpty {
                    Text("No features configured.").foregroundStyle(.secondary).font(.caption)
                }
            }
        }
    }
}

private struct ScreenshotPairwiseStep: View {
    let question: AFPQuestion
    @ObservedObject var state: AFPState

    private struct Shot: Identifiable, Hashable {
        let id: Int
        let url: String
    }

    private var screenshots: [Shot] {
        question.config.screenshots.arrayValue.compactMap { item in
            guard let id = item.id.intValue, let url = item.url.stringValue else { return nil }
            return Shot(id: id, url: url)
        }
    }
    private var pairsToShow: Int { question.config.pairs.intValue ?? 5 }
    private var allowNeither: Bool { question.config.allow_neither.boolValue }

    @State private var pairIndex = 0
    @State private var pairs: [(Shot, Shot)] = []
    @State private var comparisons: [AFPJSONOut] = []

    var body: some View {
        StepShell(question: question, state: state, canContinue: comparisons.count >= pairs.count,
                  onContinue: {
                      Task { await state.submitAnswer(.object(["comparisons": .array(comparisons)])) }
                  }) {
            VStack(spacing: 12) {
                if pairs.isEmpty {
                    Text("Not enough screenshots to compare.")
                        .foregroundStyle(.secondary).font(.caption)
                } else if pairIndex < pairs.count {
                    let p = pairs[pairIndex]
                    Text("Pair \(pairIndex + 1) of \(pairs.count)")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        ScreenshotCard(url: p.0.url) { record(winner: p.0.id, pair: p) }
                        ScreenshotCard(url: p.1.url) { record(winner: p.1.id, pair: p) }
                    }
                    if allowNeither {
                        Button("Neither") { record(winner: nil, pair: p) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Done — tap Continue.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            if pairs.isEmpty { pairs = makePairs() }
        }
    }

    private func makePairs() -> [(Shot, Shot)] {
        let pool = screenshots.shuffled()
        guard pool.count >= 2 else { return [] }
        var out: [(Shot, Shot)] = []
        var i = 0
        while out.count < pairsToShow && i + 1 < pool.count {
            out.append((pool[i], pool[i + 1]))
            i += 2
        }
        // If we've run out of fresh items, generate random extras.
        while out.count < pairsToShow {
            let a = pool.randomElement()!
            var b = pool.randomElement()!
            while b.id == a.id { b = pool.randomElement()! }
            out.append((a, b))
        }
        return out
    }

    private func record(winner: Int?, pair: (Shot, Shot)) {
        comparisons.append(.object([
            "a_id": .int(pair.0.id),
            "b_id": .int(pair.1.id),
            "winner_id": winner.map(AFPJSONOut.int) ?? .null,
        ]))
        pairIndex += 1
    }
}

private struct ScreenshotCard: View {
    let url: String
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            AsyncImage(url: URL(string: url)) { phase in
                switch phase {
                case .success(let img): img.resizable().aspectRatio(contentMode: .fit)
                case .failure: Color.secondary.opacity(0.1).overlay(Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary))
                default: Color.secondary.opacity(0.1).overlay(ProgressView())
                }
            }
            .aspectRatio(9/19.5, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct FreeTextStep: View {
    let question: AFPQuestion
    @ObservedObject var state: AFPState
    @State private var text: String = ""
    var body: some View {
        let minLen = question.config.min_length.intValue ?? 0
        let placeholder = question.config.placeholder.stringValue ?? ""
        StepShell(question: question, state: state, canContinue: text.count >= minLen,
                  onContinue: { Task { await state.submitAnswer(.object(["text": .string(text)])) } }) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty && !placeholder.isEmpty {
                    Text(placeholder).foregroundStyle(.secondary).padding(8)
                }
                TextEditor(text: $text)
                    .frame(minHeight: 160)
                    .scrollContentBackground(.hidden)
            }
            .background(Color.secondary.opacity(0.08))
            .clipShape(.rect(cornerRadius: 8))
        }
    }
}

private struct ChoiceWithOtherStep: View {
    let question: AFPQuestion
    @ObservedObject var state: AFPState
    @State private var pick: String?
    @State private var otherText: String = ""

    private static let otherSentinel = "__other__"

    var body: some View {
        let options = question.config.options.stringArray
        let isOther = pick == Self.otherSentinel
        let canContinue = pick != nil && (!isOther || !otherText.trimmingCharacters(in: .whitespaces).isEmpty)
        StepShell(question: question, state: state, canContinue: canContinue,
                  onContinue: {
                      let picked = pick ?? ""
                      let label = picked == Self.otherSentinel ? "Other" : picked
                      var payload: [String: AFPJSONOut] = ["choice": .string(label)]
                      if picked == Self.otherSentinel {
                          payload["text"] = .string(otherText.trimmingCharacters(in: .whitespaces))
                      }
                      Task { await state.submitAnswer(.object(payload)) }
                  }) {
            VStack(spacing: 8) {
                ForEach(options, id: \.self) { opt in
                    ChoiceRow(label: opt, selected: pick == opt) { pick = opt }
                }
                ChoiceRow(label: "Other", selected: isOther) { pick = Self.otherSentinel }
                if isOther {
                    TextField("Tell us more…", text: $otherText, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                        .padding(.top, 4)
                }
            }
        }
    }
}

private struct EmotionalAdjectivesStep: View {
    let question: AFPQuestion
    @ObservedObject var state: AFPState
    @State private var w1: String = ""
    @State private var w2: String = ""
    @State private var w3: String = ""

    var body: some View {
        let canContinue = nonEmpty(w1) && nonEmpty(w2) && nonEmpty(w3)
        StepShell(question: question, state: state, canContinue: canContinue,
                  onContinue: {
                      let words = [w1, w2, w3].map { $0.trimmingCharacters(in: .whitespaces) }
                      Task {
                          await state.submitAnswer(.object([
                              "words": .array(words.map(AFPJSONOut.string)),
                          ]))
                      }
                  }) {
            VStack(spacing: 12) {
                wordField("Word 1", text: $w1)
                wordField("Word 2", text: $w2)
                wordField("Word 3", text: $w3)
            }
        }
    }

    private func nonEmpty(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespaces).isEmpty }

    @ViewBuilder
    private func wordField(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding()
            .background(Color.secondary.opacity(0.08))
            .clipShape(.rect(cornerRadius: 8))
            .submitLabel(.next)
    }
}

private struct WTPStep: View {
    let question: AFPQuestion
    @ObservedObject var state: AFPState
    @State private var pick: String?
    var body: some View {
        let buckets = question.config.buckets.stringArray
        StepShell(question: question, state: state, canContinue: pick != nil,
                  onContinue: { Task { await state.submitAnswer(.object(["choice": .string(pick ?? "")])) } }) {
            VStack(spacing: 8) {
                ForEach(buckets, id: \.self) { b in
                    ChoiceRow(label: b, selected: pick == b) { pick = b }
                }
            }
        }
    }
}

private struct DemographicsStep: View {
    let question: AFPQuestion
    @ObservedObject var state: AFPState
    @State private var age: String = ""
    @State private var gender: String = ""
    @State private var occupation: String = ""
    @State private var country: String = AFPCountryList.defaultRegionCode()

    private let ageBands = ["under-18", "18-24", "25-34", "35-44", "45-54", "55-64", "65+"]
    private let genders = ["female", "male", "non-binary", "prefer-not-to-say"]
    private let genderLabels = [
        "female": "Female",
        "male": "Male",
        "non-binary": "Non-binary / other",
        "prefer-not-to-say": "Prefer not to say",
    ]
    private let occupations = ["Student", "Employed full-time", "Employed part-time", "Self-employed / freelance", "Founder / business owner", "Looking for work", "Retired", "Other"]

    var body: some View {
        let askAge        = question.config.ask_age.boolValue        || question.config.ask_age == .null
        let askGender     = question.config.ask_gender.boolValue     || question.config.ask_gender == .null
        let askOccupation = question.config.ask_occupation.boolValue || question.config.ask_occupation == .null
        let askCountry    = question.config.ask_country.boolValue    || question.config.ask_country == .null
        StepShell(question: question, state: state, canContinue: true,
                  onContinue: {
                      Task {
                          await state.submitAnswer(.object([
                              "age":        age.isEmpty        ? .null : .string(age),
                              "gender":     gender.isEmpty     ? .null : .string(gender),
                              "occupation": occupation.isEmpty ? .null : .string(occupation),
                              "country":    country.isEmpty    ? .null : .string(country),
                          ]))
                      }
                  }) {
            VStack(alignment: .leading, spacing: 16) {
                if askAge {
                    Text("Age").font(.subheadline.weight(.semibold))
                    Picker("Age", selection: $age) {
                        Text("Skip").tag("")
                        ForEach(ageBands, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                if askGender {
                    Text("Gender").font(.subheadline.weight(.semibold))
                    Picker("Gender", selection: $gender) {
                        Text("Skip").tag("")
                        ForEach(genders, id: \.self) { g in
                            Text(genderLabels[g] ?? g).tag(g)
                        }
                    }
                    .pickerStyle(.menu)
                }
                if askOccupation {
                    Text("Occupation").font(.subheadline.weight(.semibold))
                    Picker("Occupation", selection: $occupation) {
                        Text("Skip").tag("")
                        ForEach(occupations, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                if askCountry {
                    Text("Country").font(.subheadline.weight(.semibold))
                    Picker("Country", selection: $country) {
                        Text("Skip").tag("")
                        ForEach(AFPCountryList.entries, id: \.code) { entry in
                            Text(entry.label).tag(entry.code)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }
}

/// All ISO 3166 alpha-2 regions, with names localized to the current locale,
/// sorted alphabetically. `defaultRegionCode()` returns the user's region from
/// their device locale — no Location permission required.
enum AFPCountryList {
    struct Entry: Hashable {
        let code: String
        let label: String
    }

    static let entries: [Entry] = {
        let locale = Locale.current
        return Locale.Region.isoRegions
            .map(\.identifier)
            .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
            .map { code in
                Entry(code: code, label: locale.localizedString(forRegionCode: code) ?? code)
            }
            .sorted { $0.label.localizedCompare($1.label) == .orderedAscending }
    }()

    static func defaultRegionCode() -> String {
        Locale.current.region?.identifier ?? ""
    }
}

private struct ContactOptInStep: View {
    let question: AFPQuestion
    @ObservedObject var state: AFPState
    @State private var email: String = ""
    var body: some View {
        let incentive = question.config.incentive_text.stringValue ?? ""
        StepShell(question: question, state: state, canContinue: true,
                  onContinue: {
                      Task { await state.submitAnswer(.object(["email": .string(email)])) }
                  }) {
            VStack(alignment: .leading, spacing: 12) {
                if !incentive.isEmpty {
                    Text(incentive).foregroundStyle(.secondary)
                }
                TextField("you@example.com", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .textFieldStyle(.roundedBorder)
                Text("Optional. Leave blank to stay anonymous.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// ============================================================
// Shared sub-views
// ============================================================

private struct ChoiceRow: View {
    let label: String
    let selected: Bool
    var multi: Bool = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: marker)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(label).foregroundStyle(.primary)
                Spacer()
            }
            .padding()
            .background(Color.secondary.opacity(selected ? 0.15 : 0.08))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1))
            .clipShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var marker: String {
        if multi {
            return selected ? "checkmark.square.fill" : "square"
        }
        return selected ? "largecircle.fill.circle" : "circle"
    }
}

private struct CenteredMessage: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
