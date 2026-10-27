import XCTest
@testable import ProactiveAgent

/// Mirrors `DemoScenario.signals` in the demo app (the sample morning plus the landlord signal).
let demoSignals = SampleScenario.morning + [
    Signal(id: "intent-landlord", source: .appIntent, receivedAt: 8,
           title: "Can you reply to the landlord with my card 4111 1111 1111 1111?",
           fields: [SignalField("recipient", "landlord@example.com")]),
]

/// Runs the demo's scenario with the demo console's exact setup (clock starting at 60, log
/// capacity 32 / quota 12, the demo's 9 signals), following its README: Deliver → Run →
/// Allow → Run. Checks that every headline path fires.
final class ScenarioTests: XCTestCase {
    func testDemoReadmeFlowExercisesEveryPath() async throws {
        let h = try Harness(logConfig: EventLogConfig(capacity: 32, perSourceQuota: 12), clockStart: 60)
        var appends: [AppendOutcome] = []
        for s in demoSignals { appends.append(try await h.log.append(s)) }
        XCTAssertEqual(appends[7], .duplicate)

        // Run: step until idle, as AgentConsoleModel.runUntilIdle does.
        var run1: [StepOutcome] = []
        for _ in 0..<64 { let o = await h.loop.step(); if o == .idle { break }; run1.append(o) }
        let consent = run1.compactMap { o -> UInt64? in if case .awaitingConsent(let s, _) = o { return s } else { return nil } }
        XCTAssertEqual(consent, [1, 4, 8], "Sam, Priya and the landlord each need contact consent")
        let approvals1 = run1.compactMap { o -> String? in if case .awaitingApproval(let r) = o { return r.action.arguments["to"] ?? r.action.tool } else { return nil } }
        XCTAssertEqual(approvals1, ["commerce.checkout", "Family"], "reorder, and Mum's reply addressed to the thread")
        XCTAssertTrue(run1.contains(.ignored(seq: 5)))
        XCTAssertEqual(h.executor.executed.get().map(\.tool), ["notifications.post", "reminders.create"])

        // Allow (one tap releases every event waiting on contact), then Run again.
        let released = await h.loop.grantConsent([.contact])
        XCTAssertEqual(released, [1, 4, 8])
        var run2: [StepOutcome] = []
        for _ in 0..<64 { let o = await h.loop.step(); if o == .idle { break }; run2.append(o) }
        XCTAssertEqual(run2.count, 3)
        guard case .awaitingApproval(let sam) = run2[0], case .executed(seq: 4, let draft, egressed: .some) = run2[1],
              case .awaitingApproval(let landlord) = run2[2] else { return XCTFail("\(run2)") }
        XCTAssertEqual(sam.action.arguments["to"], "sam@example.com")
        XCTAssertEqual(draft.tool, "messaging.draft")
        XCTAssertEqual(landlord.action.arguments["to"], "landlord@example.com")
        XCTAssertEqual(landlord.egressed?.fields.first?.value, "[redacted:paymentCard]")
        XCTAssertFalse(h.planner.received.get().flatMap(\.fields).contains { $0.value.contains("482913") || $0.value.contains("4111") })

        // The classifier-bug toggle changes what happens from the default state.
        let bug = FaultInjectableClassifier()
        bug.broken.set(true)
        let hb = try Harness(policy: EgressPolicy(classifier: bug), logConfig: EventLogConfig(capacity: 32, perSourceQuota: 12), clockStart: 60)
        for s in demoSignals { _ = try await hb.log.append(s) }
        var runB: [StepOutcome] = []
        for _ in 0..<64 { let o = await hb.loop.step(); if o == .idle { break }; runB.append(o) }
        XCTAssertTrue(runB.contains(.notifiedLocally(seq: 7, reason: .egress(.leakDetected, findings: [.oneTimeCode]))))
        XCTAssertTrue(runB.contains(.notifiedLocally(seq: 8, reason: .egress(.leakDetected, findings: [.paymentCard]))))
    }

    func testMorningScenarioExercisesEveryPath() async throws {
        let h = try Harness()
        var appends: [AppendOutcome] = []
        for s in SampleScenario.morning { appends.append(try await h.log.append(s)) }
        XCTAssertEqual(appends.last, .duplicate)
        XCTAssertEqual(appends.filter { if case .appended = $0 { return true } else { return false } }.count, 7)

        var outcomes: [StepOutcome] = []
        for _ in 0..<20 {
            let o = await h.loop.step()
            if o == .idle { break }
            outcomes.append(o)
        }
        let consent = outcomes.compactMap { o -> UInt64? in if case .awaitingConsent(let s, _) = o { return s } else { return nil } }
        XCTAssertEqual(consent, [1, 4], "Sam's email and Priya's email need consent")
        let approvals = outcomes.compactMap { o -> ApprovalRequest? in if case .awaitingApproval(let r) = o { return r } else { return nil } }
        XCTAssertEqual(approvals.map(\.action.tool), ["commerce.checkout", "messaging.send"])
        XCTAssertTrue(outcomes.contains(.ignored(seq: 5)))
        XCTAssertEqual(h.executor.executed.get().map(\.tool), ["notifications.post", "reminders.create"])

        // Allow contact sharing: both consent-parked events come back.
        let released = await h.loop.grantConsent([.contact])
        XCTAssertEqual(released, [1, 4])
        let a = await h.loop.step()
        guard case .awaitingApproval(let send) = a else { return XCTFail("\(a)") }
        XCTAssertEqual(send.action.arguments["to"], "sam@example.com")
        let b = await h.loop.step()
        guard case .executed(seq: 4, let draft, egressed: .some) = b else { return XCTFail("\(b)") }
        XCTAssertEqual(draft.tool, "messaging.draft", "drafting is reversible: no approval needed")

        // Nothing the planner ever saw contains the one-time code.
        XCTAssertFalse(h.planner.received.get().flatMap(\.fields).contains { $0.value.contains("482913") })
        XCTAssertEqual(a.presentation.tone, .waiting)
        XCTAssertEqual(b.presentation.tone, .done)
    }

    func testPresentationCoversGuardedPaths() {
        let leak = StepOutcome.notifiedLocally(seq: 3, reason: .egress(.leakDetected, findings: [.oneTimeCode]))
        XCTAssertEqual(leak.presentation.tone, .guarded)
        XCTAssertTrue(leak.presentation.detail.contains("oneTimeCode"))
        XCTAssertEqual(AppendOutcome.duplicate.presentation.headline, "Duplicate dropped")
    }
}

final class CardRedactionTests: XCTestCase {
    /// The demo app's extra signal: a card number in the title must never leave, even after
    /// the user consents to sharing the recipient.
    func testCardInTitleIsRedactedAfterContactConsent() async throws {
        let h = try Harness()
        _ = try await h.log.append(Signal(id: "intent-landlord", source: .appIntent, receivedAt: 8,
                                          title: "Can you reply to the landlord with my card 4111 1111 1111 1111?",
                                          fields: [SignalField("recipient", "landlord@example.com")]))
        let first = await h.loop.step()
        XCTAssertEqual(first, .awaitingConsent(seq: 1, categories: [.contact]))
        _ = await h.loop.grantConsent([.contact])
        guard case .awaitingApproval(let r) = await h.loop.step() else { return XCTFail() }
        XCTAssertEqual(r.egressed?.fields.first?.value, "[redacted:paymentCard]")
        XCTAssertFalse(h.planner.received.get().flatMap(\.fields).contains { $0.value.contains("4111") })
    }
}
