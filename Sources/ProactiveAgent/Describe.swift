// Human-readable descriptions of loop outcomes. Lives in the core module (not the UI) so the
// wording is covered by Linux tests and shared by any front end: SwiftUI, logs, or a CLI.

public enum OutcomeTone: String, Sendable, Hashable {
    case done, waiting, guarded, deferred, failed, neutral
}

public struct OutcomeDescription: Sendable, Hashable {
    public let headline: String
    public let detail: String
    public let tone: OutcomeTone

    public init(headline: String, detail: String, tone: OutcomeTone) {
        self.headline = headline
        self.detail = detail
        self.tone = tone
    }
}

extension LocalReason {
    public var explanation: String {
        switch self {
        case .modelUnavailable: return "on-device model unavailable, so the agent only notified"
        case .egress(.leakDetected, let findings):
            let kinds = findings.map(\.rawValue).sorted().joined(separator: ", ")
            return "leak scanner blocked egress (\(kinds)); nothing was sent"
        case .egress(.payloadTooLarge, _): return "payload over the egress cap; kept on device"
        case .egress(.nothingToShare, _): return "everything was never-share data; kept on device"
        case .cloudRetriesExhausted: return "cloud planner failed every retry; fell back to a notification"
        case .plannerDeclined: return "the planner proposed nothing"
        case .undisclosedTool(let tool): return "planner proposed \(tool), outside the disclosed module; refused"
        case .exceedsStageBudget: return "this request costs more than the stage's whole budget; notified instead"
        }
    }
}

extension StepOutcome {
    public var presentation: OutcomeDescription {
        switch self {
        case .idle:
            return OutcomeDescription(headline: "Idle", detail: "nothing claimable right now", tone: .neutral)
        case .busy:
            return OutcomeDescription(headline: "Busy", detail: "another step is running", tone: .neutral)
        case .ignored(let seq):
            return OutcomeDescription(headline: "#\(seq) ignored", detail: "triaged as not worth your attention", tone: .neutral)
        case .executed(let seq, let action, let egressed):
            let via: String
            if let egressed {
                let redacted = egressed.fields.filter(\.redacted).count
                via = "planned in the cloud from an egress ticket (\(redacted) of \(egressed.fields.count) fields redacted)"
            } else {
                via = "planned on device"
            }
            return OutcomeDescription(headline: "#\(seq) \(action.tool)", detail: "\(action.summary) — \(via)", tone: .done)
        case .notifiedLocally(let seq, let reason):
            return OutcomeDescription(headline: "#\(seq) notified instead of acting", detail: reason.explanation, tone: .guarded)
        case .awaitingConsent(let seq, let categories):
            let kinds = categories.map(\.rawValue).sorted().joined(separator: ", ")
            return OutcomeDescription(headline: "#\(seq) needs consent", detail: "would share: \(kinds)", tone: .waiting)
        case .awaitingApproval(let request):
            return OutcomeDescription(headline: "#\(request.eventSeq) needs approval", detail: request.action.summary, tone: .waiting)
        case .duplicateSuppressed(let seq):
            return OutcomeDescription(headline: "#\(seq) duplicate suppressed", detail: "journal shows this action already ran", tone: .guarded)
        case .retryScheduled(let seq, let attempt, _):
            return OutcomeDescription(headline: "#\(seq) retry \(attempt) scheduled", detail: "exponential backoff", tone: .deferred)
        case .deadLettered(let seq):
            return OutcomeDescription(headline: "#\(seq) dead-lettered", detail: "action failed every attempt", tone: .failed)
        case .deferred(let seq, let reason, _):
            return OutcomeDescription(headline: "#\(seq) deferred", detail: "reason: \(reason.rawValue)", tone: .deferred)
        case .rejectedByUser(let seq):
            return OutcomeDescription(headline: "#\(seq) rejected", detail: "you said no; nothing ran", tone: .neutral)
        case .approvalExpired(let seq):
            return OutcomeDescription(headline: "#\(seq) approval expired", detail: "returned to the queue to re-plan", tone: .deferred)
        case .approvalMismatch(let id):
            return OutcomeDescription(headline: "Approval \(id) mismatch", detail: "the approved digest differs from the action on file", tone: .failed)
        case .unknownRequest(let id):
            return OutcomeDescription(headline: "Approval \(id) unknown", detail: "already used or expired", tone: .neutral)
        case .storageFailure(let message):
            return OutcomeDescription(headline: "Storage failure", detail: message, tone: .failed)
        }
    }
}

extension AppendOutcome {
    public var presentation: OutcomeDescription {
        switch self {
        case .appended(let seq):
            return OutcomeDescription(headline: "#\(seq) logged", detail: "accepted into the durable log", tone: .neutral)
        case .appendedShedding(let seq, let shed):
            return OutcomeDescription(headline: "#\(seq) logged, #\(shed) shed", detail: "log full: oldest pending of the busiest source dropped", tone: .deferred)
        case .duplicate:
            return OutcomeDescription(headline: "Duplicate dropped", detail: "same signal id already seen", tone: .guarded)
        case .rejected(.sourceQuota(let source)):
            return OutcomeDescription(headline: "Rejected", detail: "\(source.rawValue) is over its quota", tone: .deferred)
        case .rejected(.full):
            return OutcomeDescription(headline: "Rejected", detail: "log full and nothing sheddable", tone: .failed)
        case .rejected(.sequenceExhausted):
            return OutcomeDescription(headline: "Rejected", detail: "sequence space exhausted", tone: .failed)
        }
    }
}
