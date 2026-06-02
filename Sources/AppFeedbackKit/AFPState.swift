import Foundation
import SwiftUI
import Combine

/// Drives the questionnaire flow: holds the loaded config, current step,
/// pending answer state, and writes back to the server.
@MainActor
final class AFPState: ObservableObject {

    enum Phase: Equatable {
        case loading
        case ready
        case empty           // questionnaire has no questions / inactive
        case error(String)
        case completed
    }

    @Published var phase: Phase = .loading
    @Published var stepIndex: Int = 0
    @Published var responseId: Int?
    @Published var skippedCount: Int = 0

    private(set) var project: AFPProject?
    private(set) var questions: [AFPQuestion] = []

    /// Step we should currently render. Returns nil if past the last question.
    var currentQuestion: AFPQuestion? {
        guard stepIndex >= 0, stepIndex < questions.count else { return nil }
        return questions[stepIndex]
    }

    var totalSteps: Int { questions.count }
    var progress: Double {
        guard totalSteps > 0 else { return 0 }
        return Double(stepIndex) / Double(totalSteps)
    }

    private let kit: AppFeedbackKit
    /// StoreKit subscriptions, loaded once when load() runs and reused for the
    /// rest of the session so we don't re-probe StoreKit on every answer.
    private var subscriptionsCache: [AFPJSONOut] = []

    init() {
        self.kit = AppFeedbackKit.shared
    }

    private func deviceContext() -> AFPDeviceContext {
        AFPDeviceContext.current(
            launches: kit.storage.launchCount,
            firstLaunch: kit.storage.firstLaunchAt,
            subscriptions: subscriptionsCache
        )
    }

    func load() async {
        phase = .loading
        // Fetch StoreKit entitlements once at load — bounded timeout in the
        // probe means this never blocks more than ~1.5s.
        subscriptionsCache = await AFPDeviceProbe.subscriptions()
        do {
            let resp: AFPConfigResponse = try await kit.client.post(
                path: "/api/config",
                body: deviceContext()
            )
            project = resp.project
            questions = resp.questionnaire.questions
            print("[AFP] /api/config → project=\(resp.project.name) status=\(resp.project.status) active=\(resp.questionnaire.active) questions=\(questions.count) types=\(questions.map(\.type))")
            if !resp.questionnaire.active || questions.isEmpty {
                phase = .empty
            } else {
                stepIndex = 0
                phase = .ready
            }
        } catch {
            print("[AFP] /api/config FAILED: \(error)")
            phase = .error(describe(error))
        }
    }

    /// Submit current answer + advance. If the question's type is not in the
    /// known renderer registry we fire-and-forget a `client_skipped_unknown_type`
    /// event and skip the step — this is the forward-compat invariant.
    func submitAnswer(_ value: AFPJSONOut, skipped: Bool = false) async {
        guard let q = currentQuestion else { return }

        if !skipped {
            if q.type == "sean_ellis" {
                if case .object(let dict) = value, case .string(let pick) = dict["choice"] {
                    kit.config?.onSatisfaction?(.seanEllis(pick))
                }
            } else if q.type == "nps" {
                if case .object(let dict) = value, case .int(let score) = dict["score"] {
                    kit.config?.onSatisfaction?(.nps(score))
                }
            }
        }

        do {
            let resp: AFPAnswerResponse = try await kit.client.post(
                path: "/api/answer",
                body: AFPAnswerBody.make(
                    questionId: q.id,
                    responseId: responseId,
                    value: value,
                    skipped: skipped,
                    launches: kit.storage.launchCount
                )
            )
            responseId = resp.response_id
        } catch {
            // Soft-fail: we still advance so a transient network blip
            // doesn't strand the user mid-flow.
        }
        advance()
    }

    /// For unknown types — increment a skipped counter and report telemetry,
    /// without writing an `answers` row. Advances FIRST so a slow/failing
    /// /api/event call can't strand the user on a spinner.
    func skipUnknown(type: String, questionId: Int) async {
        skippedCount += 1
        advance()
        let body = AFPEventBody(
            name: "client_skipped_unknown_type",
            data: .object([
                "type": .string(type),
                "question_id": .int(questionId),
            ]),
            app_version: AFPDeviceContext.current(launches: kit.storage.launchCount).app_version,
            os_version: AFPDeviceContext.current(launches: kit.storage.launchCount).os_version,
            locale: Locale.current.identifier,
            sessions: kit.storage.launchCount
        )
        _ = try? await kit.client.post(path: "/api/event", body: body) as AFPSimpleResponse
    }

    func advance() {
        if stepIndex + 1 >= questions.count {
            Task { await complete() }
        } else {
            stepIndex += 1
        }
    }

    func goBack() {
        if stepIndex > 0 { stepIndex -= 1 }
    }

    func complete() async {
        guard let responseId = responseId else {
            // No answers were stored (every question got auto-skipped). Treat
            // as completion anyway so we honour cooldown.
            kit.storage.recordCompleted()
            phase = .completed
            return
        }
        let body = AFPCompleteBody(
            response_id: responseId,
            app_version: AFPDeviceContext.current(launches: kit.storage.launchCount).app_version,
            os_version: AFPDeviceContext.current(launches: kit.storage.launchCount).os_version,
            locale: Locale.current.identifier,
            sessions: kit.storage.launchCount
        )
        _ = try? await kit.client.post(path: "/api/complete", body: body) as AFPSimpleResponse
        kit.storage.recordCompleted()
        phase = .completed
    }

    func dismiss() async {
        let body = AFPDismissBody(
            response_id: responseId,
            app_version: AFPDeviceContext.current(launches: kit.storage.launchCount).app_version,
            os_version: AFPDeviceContext.current(launches: kit.storage.launchCount).os_version,
            locale: Locale.current.identifier,
            sessions: kit.storage.launchCount
        )
        _ = try? await kit.client.post(path: "/api/dismiss", body: body) as AFPSimpleResponse
        kit.storage.recordDismissed()
    }

    private func describe(_ error: Error) -> String {
        if let afp = error as? AFPClient.AFPError {
            switch afp {
            case .notConfigured:                return "AppFeedbackKit not configured"
            case .server(_, let m, _):          return m
            case .decode:                       return "Could not decode server response"
            case .transport(let e):             return e.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
