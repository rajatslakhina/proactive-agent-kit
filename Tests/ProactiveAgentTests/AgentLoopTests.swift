import XCTest
@testable import ProactiveAgent

final class AgentLoopTests: XCTestCase {
    func testLocalIntentExecutesWithoutAnyEgress() async throws {
        let h = try Harness()
        _ = try await h.log.append(Fixtures.notification("n1", "Lunch moved to 1pm"))
        let outcome = await h.loop.step()
        guard case .executed(seq: 1, let action, egressed: nil) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(action.tool, "notifications.post")
        XCTAssertTrue(h.planner.received.get().isEmpty)
        let idle = await h.loop.step()
        XCTAssertEqual(idle, .idle)
    }

    func testConsentThenApprovalThenExactlyOneExecution() async throws {
        let h = try Harness()
        _ = try await h.log.append(Fixtures.lateMessage)

        let first = await h.loop.step()
        XCTAssertEqual(first, .awaitingConsent(seq: 1, categories: [.contact]))
        XCTAssertTrue(h.planner.received.get().isEmpty, "nothing leaves before consent")
        let parked = await h.loop.step()
        XCTAssertEqual(parked, .idle, "a parked event is not claimable")

        let released = await h.loop.grantConsent([.contact])
        XCTAssertEqual(released, [1])

        let second = await h.loop.step()
        guard case .awaitingApproval(let request) = second else { return XCTFail("\(second)") }
        XCTAssertEqual(request.action.tool, "messaging.send")
        XCTAssertEqual(request.action.arguments["to"], "sam@example.com")
        XCTAssertTrue(h.executor.executed.get().isEmpty, "consequential: nothing runs before approval")

        let approved = await h.loop.approve(request.id, digest: request.digest)
        guard case .executed(seq: 1, _, egressed: .some) = approved else { return XCTFail("\(approved)") }
        let again = await h.loop.approve(request.id, digest: request.digest)
        XCTAssertEqual(again, .unknownRequest(request.id), "approvals are single-use")
        XCTAssertEqual(h.executor.executed.get().map(\.tool), ["messaging.send"])
        let live = await h.log.liveCount
        XCTAssertEqual(live, 0)
    }

    func testApprovalIsBoundToTheExactAction() async throws {
        let h = try Harness()
        _ = await h.loop.grantConsent([.contact])
        _ = try await h.log.append(Fixtures.lateMessage)
        guard case .awaitingApproval(let request) = await h.loop.step() else { return XCTFail() }
        let tampered = PlannedAction(tool: "messaging.send", arguments: ["to": "someone@else.example", "body": "x"], summary: "")
        let mismatch = await h.loop.approve(request.id, digest: tampered.digest)
        XCTAssertEqual(mismatch, .approvalMismatch(requestID: request.id))
        XCTAssertTrue(h.executor.executed.get().isEmpty)
        let ok = await h.loop.approve(request.id, digest: request.digest)
        guard case .executed = ok else { return XCTFail("the real approval still works: \(ok)") }
    }

    func testExpiredApprovalReturnsTheEventAndAsksAgain() async throws {
        let h = try Harness(config: AgentLoopConfig(approvalTTL: 60))
        _ = try await h.log.append(Fixtures.reorder)
        guard case .awaitingApproval(let first) = await h.loop.step() else { return XCTFail() }
        h.clock.advance(by: 61)
        let expired = await h.loop.step()
        XCTAssertEqual(expired, .approvalExpired(seq: 1))
        let late = await h.loop.approve(first.id, digest: first.digest)
        XCTAssertEqual(late, .unknownRequest(first.id))
        guard case .awaitingApproval(let second) = await h.loop.step() else { return XCTFail("re-asks") }
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertTrue(h.executor.executed.get().isEmpty)
    }

    func testRejectCompletesWithoutExecuting() async throws {
        let h = try Harness()
        _ = try await h.log.append(Fixtures.reorder)
        guard case .awaitingApproval(let r) = await h.loop.step() else { return XCTFail() }
        let rejected = await h.loop.reject(r.id)
        XCTAssertEqual(rejected, .rejectedByUser(seq: 1))
        XCTAssertTrue(h.executor.executed.get().isEmpty)
        let live = await h.log.liveCount
        XCTAssertEqual(live, 0)
    }

    func testPlannerCannotUseAToolOutsideTheDisclosedModule() async throws {
        let h = try Harness()
        h.planner.faults.mutate { $0.rogue = true }
        _ = try await h.log.append(Fixtures.reorder)
        let outcome = await h.loop.step()
        XCTAssertEqual(outcome, .notifiedLocally(seq: 1, reason: .undisclosedTool("messaging.send")))
        XCTAssertEqual(h.executor.executed.get().map(\.tool), ["notifications.post"])
    }

    func testOfflineDefersWithoutBurningAttemptsOrBudget() async throws {
        let h = try Harness()
        h.planner.faults.mutate { $0.offline = true }
        _ = try await h.log.append(Fixtures.reorder)
        let budgetBefore = await h.loop.status().cloudBudgetRemaining
        let outcome = await h.loop.step()
        XCTAssertEqual(outcome, .deferred(seq: 1, reason: .offline, until: 1_060))
        let event = await h.log.event(1)
        XCTAssertEqual(event?.attempts, 0)
        let status = await h.loop.status()
        XCTAssertEqual(status.cloudBudgetRemaining, budgetBefore, "offline requests are refunded")
        XCTAssertEqual(status.metrics.ticketsIssued, 0)

        h.planner.faults.mutate { $0.offline = false }
        let tooEarly = await h.loop.step()
        XCTAssertEqual(tooEarly, .idle)
        h.clock.advance(by: 60)
        guard case .awaitingApproval = await h.loop.step() else { return XCTFail("should proceed once online") }
    }

    func testTransientFailuresBackOffThenFallBackToNotifying() async throws {
        let h = try Harness(config: AgentLoopConfig(maxAttempts: 3, baseBackoff: 2))
        h.planner.faults.mutate { $0.failuresRemaining = 10 }
        _ = try await h.log.append(Fixtures.reorder)
        let a = await h.loop.step()
        XCTAssertEqual(a, .retryScheduled(seq: 1, attempt: 1, at: 1_002))
        let idle = await h.loop.step()
        XCTAssertEqual(idle, .idle)
        h.clock.advance(by: 2)
        let b = await h.loop.step()
        XCTAssertEqual(b, .retryScheduled(seq: 1, attempt: 2, at: 1_006))
        h.clock.advance(by: 4)
        let c = await h.loop.step()
        XCTAssertEqual(c, .notifiedLocally(seq: 1, reason: .cloudRetriesExhausted))
        XCTAssertEqual(h.executor.executed.get().map(\.tool), ["notifications.post"])
    }

    func testExecutorFailuresDeadLetterAfterMaxAttempts() async throws {
        let h = try Harness(config: AgentLoopConfig(maxAttempts: 2, baseBackoff: 1))
        h.executor.failuresRemaining.set(5)
        _ = try await h.log.append(Fixtures.notification("n1", "Lunch moved"))
        let a = await h.loop.step()
        XCTAssertEqual(a, .retryScheduled(seq: 1, attempt: 1, at: 1_001))
        h.clock.advance(by: 1)
        let b = await h.loop.step()
        XCTAssertEqual(b, .deadLettered(seq: 1))
        let letters = await h.log.snapshot().deadLetters
        XCTAssertEqual(letters.map(\.reason), [.retriesExhausted])
    }

    func testLowPowerDefersCloudWorkButNotLocalWork() async throws {
        let h = try Harness()
        let lowPower = EnergyState(batteryLevel: 0.9, lowPowerMode: true)
        _ = try await h.log.append(Fixtures.reorder)
        _ = try await h.log.append(Fixtures.otp)
        let a = await h.loop.step(energy: lowPower)
        XCTAssertEqual(a, .deferred(seq: 1, reason: .energy, until: 1_060))
        let b = await h.loop.step(energy: lowPower)
        guard case .executed(seq: 2, let action, egressed: nil) = b else { return XCTFail("\(b)") }
        XCTAssertEqual(action.tool, "notifications.post")
        XCTAssertTrue(h.planner.received.get().isEmpty)
    }

    func testUnavailableModelOnlyEverNotifies() async throws {
        let h = try Harness(triage: UnavailableTriage())
        _ = try await h.log.append(Fixtures.reorder)
        let outcome = await h.loop.step()
        XCTAssertEqual(outcome, .notifiedLocally(seq: 1, reason: .modelUnavailable))
        XCTAssertTrue(h.planner.received.get().isEmpty)
        XCTAssertEqual(h.executor.executed.get().map(\.tool), ["notifications.post"])
    }

    func testCloudBudgetDefersUntilTheWindowRefills() async throws {
        let h = try Harness(cloudTokensPerHour: 700, config: AgentLoopConfig(approvalTTL: 10_000))
        _ = try await h.log.append(Fixtures.reorder)
        _ = try await h.log.append(Signal(id: "buy-2", source: .appIntent, receivedAt: 0,
                                          title: "Running low on oat milk, reorder?", fields: [SignalField("item", "oat milk")]))
        guard case .awaitingApproval = await h.loop.step() else { return XCTFail() }
        let second = await h.loop.step()
        XCTAssertEqual(second, .deferred(seq: 2, reason: .cloudBudget, until: 4_600))
        h.clock.advance(by: 3_600)
        guard case .awaitingApproval = await h.loop.step() else { return XCTFail("refilled") }
        let metrics = await h.loop.status().metrics
        XCTAssertEqual(metrics.disclosedSchemaTokens, 2 * 660, "only the commerce module was disclosed")
        XCTAssertEqual(metrics.eagerSchemaTokens, 2 * ToolCatalog.standard.eagerSchemaTokens)
    }

    func testRedactedOneTimeCodeNeverReachesThePlanner() async throws {
        let h = try Harness()
        _ = try await h.log.append(Signal(id: "m", source: .notification, receivedAt: 0,
                                          title: "Mum: reply with the code 482913 please", fields: [SignalField("thread", "Family")]))
        // messaging.send is consequential, so the plan parks for approval.
        guard case .awaitingApproval(let r) = await h.loop.step() else { return XCTFail() }
        XCTAssertEqual(r.egressed?.fields.first?.value, "[redacted:oneTimeCode]")
        let sent = h.planner.received.get()
        XCTAssertEqual(sent.count, 1)
        XCTAssertFalse(sent.flatMap(\.fields).contains { $0.value.contains("482913") })
    }

    func testIgnoredSignalsDoNothing() async throws {
        let h = try Harness()
        _ = try await h.log.append(Fixtures.promo)
        let outcome = await h.loop.step()
        XCTAssertEqual(outcome, .ignored(seq: 1))
        XCTAssertTrue(h.executor.executed.get().isEmpty)
    }

    /// A real concurrent caller: the second `step` arrives while the first is suspended inside
    /// the triage model. It must be refused, not interleaved.
    func testConcurrentStepIsRefusedNotInterleaved() async throws {
        let gate = Gate()
        let h = try Harness(triage: GatedTriage(gate: gate))
        _ = try await h.log.append(Fixtures.notification("a", "one"))
        _ = try await h.log.append(Fixtures.notification("b", "two"))
        let loop = h.loop
        let first = Task { await loop.step() }
        while !(await gate.entered) { await Task.yield() }
        // In its own task, observed before the gate opens: a correct guard answers `.busy` on its
        // own; a broken one blocks on the gate and fails the assertion instead of hanging.
        let answered = Locked<StepOutcome?>(nil)
        let second = Task { let o = await loop.step(); answered.set(o); return o }
        let early = try await waitForValue(answered)
        await gate.open()
        _ = await second.value
        XCTAssertEqual(early, .busy)
        guard case .executed(seq: 1, _, _) = await first.value else { return XCTFail() }
    }

    /// Crash after the side effect but before the log is updated: on restart the event is
    /// re-processed, and the persisted journal stops the action from running twice.
    func testJournalPreventsADoubleSideEffectAfterACrash() async throws {
        let (count, journal) = try await crashAfterExecute()
        XCTAssertEqual(count, 1)
        let storage = try XCTUnwrap(lastStorage)
        let log = try EventLog(storage: storage)
        let executor = RecordingExecutor()
        let loop = AgentLoop(log: log, planner: SimulatedCloudPlanner(), executor: executor, journal: journal, clock: { 2_000 })
        let outcome = await loop.step()
        XCTAssertEqual(outcome, .duplicateSuppressed(seq: 1))
        XCTAssertTrue(executor.executed.get().isEmpty)
    }

    /// Mutation check for the test above: with the journal dropped, the side effect repeats.
    func testWithoutTheJournalTheSideEffectRepeats() async throws {
        _ = try await crashAfterExecute()
        let storage = try XCTUnwrap(lastStorage)
        let log = try EventLog(storage: storage)
        let executor = RecordingExecutor()
        let loop = AgentLoop(log: log, planner: SimulatedCloudPlanner(), executor: executor, journal: ActionJournal(), clock: { 2_000 })
        guard case .executed = await loop.step() else { return XCTFail() }
        XCTAssertEqual(executor.executed.get().count, 1, "a second, duplicate execution")
    }

    private var lastStorage: FlakyStorage?

    private func crashAfterExecute() async throws -> (Int, ActionJournal) {
        let storage = FlakyStorage(failAfter: 2) // save 1: append, save 2: claim, save 3 (complete) fails
        let h = try Harness(storage: storage)
        _ = try await h.log.append(Fixtures.notification("n1", "Lunch moved"))
        let outcome = await h.loop.step()
        guard case .storageFailure = outcome else { XCTFail("\(outcome)"); return (0, ActionJournal()) }
        storage.failAfter = .max
        lastStorage = storage
        return (h.executor.executed.get().count, await h.loop.status().journal)
    }
}

final class AgentLoopGuardTests: XCTestCase {
    /// Double-tap: two approvals of the same request while the first is suspended in the executor.
    func testConcurrentApprovalsExecuteExactlyOnce() async throws {
        let clock = SimulatedClock(start: 1_000)
        let executor = GatedExecutor()
        let log = try EventLog(storage: InMemoryEventLogStorage())
        let loop = AgentLoop(log: log, planner: SimulatedCloudPlanner(), executor: executor, clock: clock.clock)
        _ = try await log.append(Fixtures.reorder)
        guard case .awaitingApproval(let r) = await loop.step() else { return XCTFail() }
        let first = Task { await loop.approve(r.id, digest: r.digest) }
        while !(await executor.gate.entered) { await Task.yield() }
        // The second tap runs as its own task, observed before the gate opens: a correct
        // implementation refuses it on its own; a broken one reaches the gated executor too and
        // fails the assertions below instead of hanging the test.
        let answered = Locked<StepOutcome?>(nil)
        let second = Task { let o = await loop.approve(r.id, digest: r.digest); answered.set(o); return o }
        let early = try await waitForValue(answered)
        await executor.gate.open()
        let outcomes = [await first.value, await second.value]
        XCTAssertEqual(early, .unknownRequest(r.id), "refused while the first approval is still executing")
        XCTAssertEqual(outcomes.filter { if case .executed = $0 { return true } else { return false } }.count, 1)
        XCTAssertEqual(executor.executed.get().count, 1)
    }

    func testApproveAfterTheTTLDoesNotExecute() async throws {
        let h = try Harness(config: AgentLoopConfig(approvalTTL: 60))
        _ = try await h.log.append(Fixtures.reorder)
        guard case .awaitingApproval(let r) = await h.loop.step() else { return XCTFail() }
        h.clock.advance(by: 60)
        let late = await h.loop.approve(r.id, digest: r.digest)
        XCTAssertEqual(late, .approvalExpired(seq: 1))
        XCTAssertTrue(h.executor.executed.get().isEmpty)
        let state = await h.log.event(1)?.state
        XCTAssertEqual(state, .pending, "returned to the queue to re-plan")
    }

    /// Consent granted while `step` is suspended inside `log.park`: the event must not be left
    /// parked forever with consent already in hand.
    func testConsentGrantedDuringParkRequeuesTheEvent() async throws {
        let storage = BlockingStorage(blockOnSave: 3) // 1 append, 2 claim, 3 park
        let log = try EventLog(storage: storage)
        let clock = SimulatedClock(start: 1_000)
        let loop = AgentLoop(log: log, planner: SimulatedCloudPlanner(), executor: RecordingExecutor(), clock: clock.clock)
        _ = try await log.append(Fixtures.lateMessage)
        let stepping = Task { await loop.step() }
        let deadline = Date().addingTimeInterval(10)
        while !storage.isBlocked.get() && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(storage.isBlocked.get(), "precondition: step is suspended inside park")
        let released = await loop.grantConsent([.contact]) // runs while step is suspended in park
        XCTAssertEqual(released, [], "the event isn't registered as waiting yet")
        storage.unblock()
        let outcome = await stepping.value
        XCTAssertEqual(outcome, .deferred(seq: 1, reason: .requeued, until: 1_000))
        guard case .awaitingApproval = await loop.step() else { return XCTFail("consent already granted: straight to approval") }
    }

    func testApprovalCardShowsArgumentsThatContradictTheSummary() async throws {
        let h = try Harness()
        h.planner.faults.mutate { $0.rogue = true }
        _ = await h.loop.grantConsent([.contact])
        _ = try await h.log.append(Fixtures.lateMessage)
        guard case .awaitingApproval(let r) = await h.loop.step() else { return XCTFail() }
        XCTAssertTrue(r.action.disclosure.contains("to: collector@attacker.example"))
        let friendly = PlannedAction(tool: r.action.tool, arguments: r.action.arguments, summary: "Reply to Sam")
        let mismatch = await h.loop.approve(r.id, digest: friendly.digest)
        XCTAssertEqual(mismatch, .approvalMismatch(requestID: r.id), "a different summary is a different approval")
    }

    func testTriageBudgetGateDefersBeforeRunningTheModel() async throws {
        let h = try Harness(triageTokensPerHour: 1)
        _ = try await h.log.append(Fixtures.notification("a", "Lunch moved"))
        _ = try await h.log.append(Fixtures.notification("b", "Coffee at 3"))
        guard case .executed = await h.loop.step() else { return XCTFail() } // charges > 1 token
        let second = await h.loop.step()
        XCTAssertEqual(second, .deferred(seq: 2, reason: .triageBudget, until: 4_600))
    }

    func testTriageEnergyGateDefersEvenLocalWork() async throws {
        let h = try Harness()
        _ = try await h.log.append(Fixtures.notification("a", "Lunch moved"))
        let outcome = await h.loop.step(energy: EnergyState(batteryLevel: 0.01, lowPowerMode: false))
        XCTAssertEqual(outcome, .deferred(seq: 1, reason: .energy, until: 1_060))
        XCTAssertTrue(h.executor.executed.get().isEmpty)
    }

    func testRecentEgressIsCapped() async throws {
        let h = try Harness(config: AgentLoopConfig(maxRecentEgress: 1))
        _ = try await h.log.append(Fixtures.reorder)
        _ = try await h.log.append(Signal(id: "buy-2", source: .appIntent, receivedAt: 0, title: "Running low on tea, reorder?"))
        _ = await h.loop.step()
        _ = await h.loop.step()
        let status = await h.loop.status()
        XCTAssertEqual(status.metrics.ticketsIssued, 2)
        XCTAssertEqual(status.recentEgress.count, 1)
    }

    /// Deferred events that the log later sheds must not leak triage-cache entries.
    func testTriageCacheStaysBoundedWhenTheLogShedsDeferredEvents() async throws {
        let clock = SimulatedClock(start: 1_000)
        let log = try EventLog(config: EventLogConfig(capacity: 2, perSourceQuota: 1), storage: InMemoryEventLogStorage())
        let loop = AgentLoop(log: log, planner: SimulatedCloudPlanner(), executor: RecordingExecutor(),
                             triageTokensPerHour: .max, clock: clock.clock)
        let lowPower = EnergyState(batteryLevel: 0.9, lowPowerMode: true)
        let sources = SignalSource.allCases
        var triagedAndDeferred = 0
        for i in 0..<200 {
            let source = sources[i % sources.count]
            _ = try await log.append(Signal(id: "s\(i)", source: source, receivedAt: 0, title: "Running low on item \(i), reorder?"))
            // Earlier events are deferred for 60s, so each step triages the *new* event, caches it,
            // and defers it; the next append sheds one of those cached, deferred events.
            if case .deferred(_, .energy, _) = await loop.step(energy: lowPower) { triagedAndDeferred += 1 }
            clock.advance(by: 0.1)
        }
        XCTAssertGreaterThan(triagedAndDeferred, 50, "precondition: many distinct events were triaged and deferred")
        let shed = await log.snapshot().deadLetters.count
        XCTAssertGreaterThan(shed, 0, "precondition: the log shed deferred events")
        let cached = await loop.triageCacheCount
        XCTAssertLessThanOrEqual(cached, 2)
    }
}

final class AgentLoopRecoveryTests: XCTestCase {
    func testTriageBudgetRefillsAfterTheWindow() async throws {
        let h = try Harness(triageTokensPerHour: 1)
        _ = try await h.log.append(Fixtures.notification("a", "Lunch moved"))
        _ = try await h.log.append(Fixtures.notification("b", "Coffee at 3"))
        guard case .executed = await h.loop.step() else { return XCTFail() }
        guard case .deferred(seq: 2, reason: .triageBudget, _) = await h.loop.step() else { return XCTFail() }
        h.clock.advance(by: 7_200)
        guard case .executed(seq: 2, _, _) = await h.loop.step() else { return XCTFail("budget must refill, not spin") }
    }

    func testADeferralDoesNotPayForTriageTwice() async throws {
        let model = CountingTriage()
        let h = try Harness(triage: model)
        _ = try await h.log.append(Fixtures.reorder)
        _ = await h.loop.step(energy: EnergyState(batteryLevel: 0.9, lowPowerMode: true)) // triaged, deferred
        h.clock.advance(by: 60)
        guard case .awaitingApproval = await h.loop.step() else { return XCTFail() }
        XCTAssertEqual(model.calls.get(), 1)
    }

    func testRejectKeepsTheApprovalIfTheLogCannotBeWritten() async throws {
        let storage = FlakyStorage()
        let h = try Harness(storage: storage)
        _ = try await h.log.append(Fixtures.reorder)
        guard case .awaitingApproval(let r) = await h.loop.step() else { return XCTFail() }
        storage.failAfter = storage.saveCount
        guard case .storageFailure = await h.loop.reject(r.id) else { return XCTFail() }
        let pending = await h.loop.status().approvals.map(\.id)
        XCTAssertEqual(pending, [r.id], "still answerable")
        storage.failAfter = .max
        let retried = await h.loop.reject(r.id)
        XCTAssertEqual(retried, .rejectedByUser(seq: 1))
    }

    func testGrantConsentKeepsWaitingEventsIfTheLogCannotBeWritten() async throws {
        let storage = FlakyStorage()
        let h = try Harness(storage: storage)
        _ = try await h.log.append(Fixtures.lateMessage)
        _ = await h.loop.step()
        storage.failAfter = storage.saveCount
        let none = await h.loop.grantConsent([.contact])
        XCTAssertEqual(none, [])
        let waiting = await h.loop.status().awaitingConsent.keys.sorted()
        XCTAssertEqual(waiting, [1], "not stranded")
        storage.failAfter = .max
        let released = await h.loop.grantConsent([.contact])
        XCTAssertEqual(released, [1])
    }

    func testExpiredApprovalSurvivesAFailedReleaseAndIsRetried() async throws {
        let storage = FlakyStorage()
        let h = try Harness(storage: storage, config: AgentLoopConfig(approvalTTL: 60))
        _ = try await h.log.append(Fixtures.reorder)
        guard case .awaitingApproval(let r) = await h.loop.step() else { return XCTFail() }
        h.clock.advance(by: 61)
        storage.failAfter = storage.saveCount
        guard case .storageFailure = await h.loop.approve(r.id, digest: r.digest) else { return XCTFail() }
        storage.failAfter = .max
        let swept = await h.loop.step()
        XCTAssertEqual(swept, .approvalExpired(seq: 1), "the step's expiry sweep retries the release")
        XCTAssertTrue(h.executor.executed.get().isEmpty)
    }
}

/// A planner whose wording changes on every call, like a real cloud model.
final class DriftingPlanner: CloudPlanner, @unchecked Sendable {
    let calls = Locked(0)
    func plan(_ ticket: EgressTicket, intent: ProposedIntent, tools: [ToolDescriptor]) async throws -> PlannedAction? {
        let n = calls.mutate { c -> Int in c += 1; return c }
        return PlannedAction(tool: "messaging.draft", arguments: ["to": "priya", "body": "draft v\(n)"], summary: "Draft v\(n)")
    }
}

struct FixedTriage: TriageModel {
    let result: TriageResult
    func triage(_ signal: Signal) async throws -> TriageResult { result }
}

final class AgentLoopRound3Tests: XCTestCase {
    /// Crash after a cloud-planned action executed: on recovery the re-plan differs, but the
    /// side effect must still not repeat.
    func testReplanAfterCrashDoesNotRepeatTheSideEffect() async throws {
        let storage = FlakyStorage(failAfter: 2) // 1 append, 2 claim, 3 complete fails
        let log = try EventLog(storage: storage)
        let executor = RecordingExecutor()
        let planner = DriftingPlanner()
        let triage = FixedTriage(result: TriageResult(intent: .draftReply, urgency: .high, rationale: "test"))
        let loop = AgentLoop(log: log, triage: triage, planner: planner, executor: executor, clock: { 1_000 })
        _ = try await log.append(Signal(id: "cal", source: .calendar, receivedAt: 0, title: "Overlap"))
        guard case .storageFailure = await loop.step() else { return XCTFail() }
        XCTAssertEqual(executor.executed.get().count, 1)
        storage.failAfter = .max
        let journal = await loop.status().journal

        let relaunched = AgentLoop(log: try EventLog(storage: storage), triage: triage, planner: planner, executor: executor,
                                   journal: journal, clock: { 2_000 })
        let outcome = await relaunched.step()
        XCTAssertEqual(outcome, .duplicateSuppressed(seq: 1))
        XCTAssertEqual(executor.executed.get().count, 1)
        XCTAssertEqual(planner.calls.get(), 1, "suppressed before re-planning")
    }

    func testCriticalCloudWorkStillEscalatesInLowPowerMode() async throws {
        let triage = FixedTriage(result: TriageResult(intent: .purchase, urgency: .critical, rationale: "test"))
        let h = try Harness(triage: triage)
        _ = try await h.log.append(Fixtures.reorder)
        guard case .awaitingApproval = await h.loop.step(energy: EnergyState(batteryLevel: 0.9, lowPowerMode: true)) else {
            return XCTFail("critical work escalates")
        }
        XCTAssertEqual(h.planner.received.get().count, 1)
    }

    func testPartialConsentDoesNotReleaseTheEvent() async throws {
        let h = try Harness()
        _ = try await h.log.append(Signal(id: "x", source: .notification, receivedAt: 0, title: "Can you reply",
                                          fields: [SignalField("sender", "sam@example.com"), SignalField("location", "Cafe Rio")]))
        let first = await h.loop.step()
        XCTAssertEqual(first, .awaitingConsent(seq: 1, categories: [.contact, .location]))
        let partial = await h.loop.grantConsent([.contact])
        XCTAssertEqual(partial, [])
        let rest = await h.loop.grantConsent([.location])
        XCTAssertEqual(rest, [1])
    }

    func testApprovedActionThatFailsIsRetriedNotStranded() async throws {
        let h = try Harness(config: AgentLoopConfig(baseBackoff: 1))
        _ = try await h.log.append(Fixtures.reorder)
        guard case .awaitingApproval(let r) = await h.loop.step() else { return XCTFail() }
        h.executor.failuresRemaining.set(1)
        let failed = await h.loop.approve(r.id, digest: r.digest)
        XCTAssertEqual(failed, .retryScheduled(seq: 1, attempt: 1, at: 1_001))
        h.clock.advance(by: 1)
        guard case .awaitingApproval = await h.loop.step() else { return XCTFail("re-planned and asks again") }
    }

    func testRequestLargerThanTheWholeBudgetFallsBackInsteadOfWaitingForever() async throws {
        let h = try Harness(cloudTokensPerHour: 100)
        _ = try await h.log.append(Fixtures.reorder)
        let outcome = await h.loop.step()
        XCTAssertEqual(outcome, .notifiedLocally(seq: 1, reason: .exceedsStageBudget))
        let zero = try Harness(triageTokensPerHour: 0)
        _ = try await zero.log.append(Fixtures.notification("a", "Lunch"))
        let z = await zero.loop.step()
        XCTAssertEqual(z, .notifiedLocally(seq: 1, reason: .modelUnavailable))
    }

    func testRejectClearsTheTriageCache() async throws {
        let h = try Harness()
        _ = try await h.log.append(Fixtures.reorder)
        guard case .awaitingApproval(let r) = await h.loop.step() else { return XCTFail() }
        _ = await h.loop.reject(r.id)
        let cached = await h.loop.triageCacheCount
        XCTAssertEqual(cached, 0)
    }
}
