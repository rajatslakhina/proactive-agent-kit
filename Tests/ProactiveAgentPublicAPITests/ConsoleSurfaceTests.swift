import ProactiveAgent
import XCTest

/// Exercises, through the public API only, every symbol `AgentConsoleModel` and
/// `AgentConsoleView` use, following the same call sequence as the console.
final class ConsoleSurfaceTests: XCTestCase {
    func testEverythingTheConsoleCallsIsPublic() async throws {
        let clock = SimulatedClock(start: 60)
        let planner = SimulatedCloudPlanner()
        let executor = RecordingExecutor()
        let classifier = FaultInjectableClassifier()
        planner.faults.set(SimulatedCloudPlanner.Faults())
        planner.faults.mutate { $0.offline = false; $0.rogue = false }
        planner.received.set([])
        executor.executed.set([])
        classifier.broken.set(false)

        let log = try EventLog(config: EventLogConfig(capacity: 32, perSourceQuota: 12), storage: InMemoryEventLogStorage())
        let loop = AgentLoop(log: log, policy: EgressPolicy(classifier: classifier), planner: planner, executor: executor,
                             config: AgentLoopConfig(destination: "cloud-model"), clock: clock.clock)

        var timeline: [OutcomeDescription] = []
        for signal in SampleScenario.morning { timeline.append(try await log.append(signal).presentation) }
        let energy = EnergyState(batteryLevel: 0.8, lowPowerMode: false)
        for _ in 0..<64 {
            let outcome = await loop.step(energy: energy)
            if outcome == .idle || outcome == .busy { break }
            timeline.append(outcome.presentation)
        }
        timeline.append(OutcomeDescription(headline: "Consent granted", detail: "", tone: .done))
        let status = await loop.status()
        let consent = status.awaitingConsent.sorted { $0.key < $1.key }
        XCTAssertFalse(consent.isEmpty)
        let kinds = consent.first.map { $0.value.map(\.rawValue).sorted() } ?? []
        XCTAssertEqual(kinds, ["contact"])
        _ = await loop.grantConsent([.contact])
        clock.advance(by: 5 * 60)
        _ = clock.read()

        let approvals = await loop.status().approvals
        let request = try XCTUnwrap(approvals.first)
        _ = (request.id, request.action.summary, request.action.tool, request.action.disclosure, request.digest.description)
        let approved = await loop.approve(request.id, digest: request.digest)
        timeline.append(approved.presentation)
        if let other = await loop.status().approvals.first {
            timeline.append((await loop.reject(other)).presentation)
        }

        let live = await log.snapshot().live
        for event in live { _ = (event.seq, event.signal.title, event.signal.source.rawValue, event.attempts, event.state.rawValue) }
        let final = await loop.status()
        for ticket in final.recentEgress {
            _ = (ticket.destination, ticket.byteCount)
            for field in ticket.fields { _ = (field.key, field.value, field.redacted) }
        }
        let m = final.metrics
        _ = (m.executed, m.ticketsIssued, m.leaksBlocked, m.disclosedSchemaTokens, m.eagerSchemaTokens,
             final.cloudBudgetRemaining, final.triageBudgetRemaining)
        _ = (Saturating.int(clock.read()), Saturating.add(1, 2), Saturating.subtract(3, 1))
        let tones: [OutcomeTone] = [.done, .waiting, .guarded, .deferred, .failed, .neutral]
        XCTAssertEqual(Set(timeline.map(\.tone)).isSubset(of: Set(tones)), true)
        XCTAssertGreaterThan(m.executed, 0)
    }
}

private extension AgentLoop {
    func reject(_ request: ApprovalRequest) async -> StepOutcome { await reject(request.id) }
}
