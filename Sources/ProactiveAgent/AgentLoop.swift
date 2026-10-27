import Foundation

public struct AgentLoopConfig: Sendable, Hashable {
    public var destination: String
    public var maxAttempts: Int
    public var baseBackoff: Double
    public var maxBackoff: Double
    public var deferInterval: Double
    public var approvalTTL: Double
    public var consentTTL: Double
    public var energyPolicy: EnergyPolicy
    public var maxRecentEgress: Int

    public init(destination: String = "cloud-model",
                maxAttempts: Int = 3,
                baseBackoff: Double = 2,
                maxBackoff: Double = 300,
                deferInterval: Double = 60,
                approvalTTL: Double = 600,
                consentTTL: Double = 86_400,
                energyPolicy: EnergyPolicy = EnergyPolicy(),
                maxRecentEgress: Int = 20) {
        func finitePositive(_ v: Double, _ fallback: Double) -> Double { v.isFinite && v > 0 ? v : fallback }
        self.destination = destination
        self.maxAttempts = Swift.max(1, maxAttempts)
        self.baseBackoff = finitePositive(baseBackoff, 2)
        self.maxBackoff = Swift.max(self.baseBackoff, finitePositive(maxBackoff, 300))
        self.deferInterval = finitePositive(deferInterval, 60)
        self.approvalTTL = finitePositive(approvalTTL, 600)
        self.consentTTL = finitePositive(consentTTL, 86_400)
        self.energyPolicy = energyPolicy
        self.maxRecentEgress = Swift.max(0, maxRecentEgress)
    }

    /// Exponential backoff, capped. Computed in `Double` so large attempt counts cannot overflow.
    public func backoff(afterAttempt attempt: Int) -> Double {
        let exponent = Double(Swift.min(Swift.max(Saturating.subtract(attempt, 1), 0), 30))
        return Swift.min(maxBackoff, baseBackoff * pow(2, exponent))
    }
}

public enum DeferReason: String, Sendable, Hashable, Codable {
    case energy, triageBudget, cloudBudget, offline
    /// Consent arrived while the event was being parked; it goes straight back to the queue.
    case requeued
}

public enum LocalReason: Sendable, Hashable {
    case modelUnavailable
    case egress(LocalOnlyReason, findings: Set<LeakScanner.Finding>)
    case cloudRetriesExhausted
    case plannerDeclined
    /// The planner proposed a tool outside the module disclosed for this intent.
    case undisclosedTool(String)
    /// A single request costs more than the stage's entire budget, so waiting can never help.
    case exceedsStageBudget
}

public enum StepOutcome: Sendable, Hashable {
    case idle
    /// Another `step` is already running; steps are serialised, never interleaved.
    case busy
    case ignored(seq: UInt64)
    case executed(seq: UInt64, action: PlannedAction, egressed: EgressTicket?)
    /// The agent fell back to telling the user instead of acting.
    case notifiedLocally(seq: UInt64, reason: LocalReason)
    case awaitingConsent(seq: UInt64, categories: Set<DataCategory>)
    case awaitingApproval(ApprovalRequest)
    case duplicateSuppressed(seq: UInt64)
    case retryScheduled(seq: UInt64, attempt: Int, at: Double)
    case deadLettered(seq: UInt64)
    case deferred(seq: UInt64, reason: DeferReason, until: Double)
    case rejectedByUser(seq: UInt64)
    case approvalExpired(seq: UInt64)
    /// The approval presented did not match the action on file (stale or tampered UI).
    case approvalMismatch(requestID: UInt64)
    case unknownRequest(UInt64)
    case storageFailure(String)
}

public struct AgentMetrics: Sendable, Hashable {
    public var executed = 0
    public var notifiedLocally = 0
    public var ticketsIssued = 0
    public var bytesEgressed = 0
    public var leaksBlocked = 0
    public var consentPrompts = 0
    public var approvalsRequested = 0
    public var duplicatesSuppressed = 0
    /// Tool-schema tokens actually placed in the cloud model's context.
    public var disclosedSchemaTokens = 0
    /// What the same requests would have cost with every tool loaded eagerly.
    public var eagerSchemaTokens = 0
}

public struct AgentStatus: Sendable, Hashable {
    public let approvals: [ApprovalRequest]
    public let awaitingConsent: [UInt64: Set<DataCategory>]
    public let consent: ConsentLedger
    public let metrics: AgentMetrics
    public let recentEgress: [EgressTicket]
    public let triageBudgetRemaining: Int
    public let cloudBudgetRemaining: Int
    public let journal: ActionJournal
}

/// The single agent loop: claim → triage (on device) → egress policy → plan → approve → act.
///
/// Concurrency contract:
/// - `step` calls are serialised: a call that arrives while another is suspended returns `.busy`
///   (the flag is set before the first `await`, so there is no check-then-await window).
/// - `approve` removes its request from `approvals` *before* awaiting the executor, so a
///   double-tap cannot execute twice.
/// - Every decision that depends on mutable actor state (consent, budgets, journal) is made in
///   the synchronous stretch after the last `await` that precedes it, and re-validated after
///   any `await` that could have let another call change it.
public actor AgentLoop {
    private let log: EventLog
    private let triageModel: any TriageModel
    private let policy: EgressPolicy
    private let planner: any CloudPlanner
    private let executor: any ActionExecutor
    private let catalog: ToolCatalog
    private let clock: Clock
    public let config: AgentLoopConfig

    private var consent = ConsentLedger()
    private var journal: ActionJournal
    private var triageBudget: StageBudget
    private var cloudBudget: StageBudget
    private var triageCache: [UInt64: TriageResult] = [:]
    private var approvals: [UInt64: ApprovalRequest] = [:]
    private var awaitingConsent: [UInt64: Set<DataCategory>] = [:]
    private var nextApprovalID: UInt64 = 1
    private var recentEgress: [EgressTicket] = []
    private var metrics = AgentMetrics()
    private var isStepping = false

    public init(log: EventLog,
                triage: any TriageModel = HeuristicTriageModel(),
                policy: EgressPolicy = EgressPolicy(),
                planner: any CloudPlanner,
                executor: any ActionExecutor,
                catalog: ToolCatalog = .standard,
                triageTokensPerHour: Int = 4_000,
                cloudTokensPerHour: Int = 6_000,
                journal: ActionJournal = ActionJournal(),
                config: AgentLoopConfig = AgentLoopConfig(),
                clock: @escaping Clock) {
        self.log = log
        self.triageModel = triage
        self.policy = policy
        self.planner = planner
        self.executor = executor
        self.catalog = catalog
        self.clock = clock
        self.config = config
        self.journal = journal
        let now = clock()
        self.triageBudget = StageBudget(capacity: triageTokensPerHour, window: 3_600, now: now)
        self.cloudBudget = StageBudget(capacity: cloudTokensPerHour, window: 3_600, now: now)
    }

    public func status() -> AgentStatus {
        let now = clock()
        var t = triageBudget, c = cloudBudget
        t.roll(now); c.roll(now)
        return AgentStatus(approvals: approvals.values.sorted { $0.id < $1.id },
                           awaitingConsent: awaitingConsent,
                           consent: consent,
                           metrics: metrics,
                           recentEgress: recentEgress,
                           triageBudgetRemaining: t.remaining,
                           cloudBudgetRemaining: c.remaining,
                           journal: journal)
    }

    // MARK: - Human decisions

    /// Grants consent and returns every event that was waiting on it to the queue.
    public func grantConsent(_ categories: Set<DataCategory>) async -> [UInt64] {
        let now = clock()
        for category in categories {
            consent.grant(category, to: config.destination, until: now + config.consentTTL)
        }
        let ready = awaitingConsent.filter { _, needed in
            needed.allSatisfy { consent.isGranted($0, to: config.destination, now: now) }
        }.map(\.key).sorted()
        var released: [UInt64] = []
        for seq in ready {
            // Remove before the await so a concurrent grant doesn't try the same event (the log's
            // transition check would also refuse a second release; this keeps the intent explicit).
            guard let needed = awaitingConsent.removeValue(forKey: seq) else { continue }
            do {
                try await log.release(seq, notBefore: now)
                released.append(seq)
            } catch {
                // Put it back so the next grant (or a relaunch) retries instead of stranding it.
                awaitingConsent[seq] = needed
            }
        }
        return released
    }

    public func revokeConsent(_ category: DataCategory) {
        consent.revoke(category, from: config.destination)
    }

    /// Executes an approved action. `digest` must be the digest of the action the user saw.
    public func approve(_ requestID: UInt64, digest: StableDigest) async -> StepOutcome {
        guard let request = approvals[requestID] else { return .unknownRequest(requestID) }
        guard request.digest == digest else { return .approvalMismatch(requestID: requestID) }
        approvals[requestID] = nil // before any await: single use
        let now = clock()
        guard request.expiresAt > now else {
            do {
                try await log.release(request.eventSeq, notBefore: now)
            } catch {
                approvals[requestID] = request // the next step's expiry sweep retries the release
                return .storageFailure(String(describing: error))
            }
            return .approvalExpired(seq: request.eventSeq)
        }
        guard let event = await log.event(request.eventSeq) else { return .unknownRequest(requestID) }
        return await perform(event, action: request.action, egressed: request.egressed) {
            .executed(seq: event.seq, action: request.action, egressed: request.egressed)
        }
    }

    public func reject(_ requestID: UInt64) async -> StepOutcome {
        guard let request = approvals.removeValue(forKey: requestID) else { return .unknownRequest(requestID) }
        do {
            try await log.complete(request.eventSeq)
        } catch {
            approvals[requestID] = request // still answerable; nothing ran
            return .storageFailure(String(describing: error))
        }
        triageCache[request.eventSeq] = nil
        return .rejectedByUser(seq: request.eventSeq)
    }

    // MARK: - The loop

    public func step(energy: EnergyState = .nominal) async -> StepOutcome {
        guard !isStepping else { return .busy }
        isStepping = true
        defer { isStepping = false }

        let now = clock()
        if let expired = await expireApprovals(now: now) { return expired }

        let event: LoggedEvent
        do {
            guard let claimed = try await log.claimNext(now: now) else { return .idle }
            event = claimed
        } catch {
            return .storageFailure(String(describing: error))
        }

        // 0. A signal whose side effect already ran (crash between execute and complete) is
        //    finished here, before any re-triage, re-plan or fresh approval card.
        if journal.contains(ActionJournal.key(signalID: event.signal.id)) {
            metrics.duplicatesSuppressed = Saturating.add(metrics.duplicatesSuppressed, 1)
            do { try await log.complete(event.seq) } catch { return .storageFailure(String(describing: error)) }
            triageCache[event.seq] = nil
            return .duplicateSuppressed(seq: event.seq)
        }

        // 1. Triage on device (cached per event so a deferral doesn't pay for it twice).
        let triage: TriageResult
        if let cached = triageCache[event.seq] {
            triage = cached
        } else {
            guard config.energyPolicy.allowsTriage(energy) else { return await deferEvent(event, .energy, now: now) }
            triageBudget.roll(now) // `remaining` must reflect the current window, not the last charged one
            if triageBudget.capacity == 0 {
                // A zero budget would defer forever; treat it as "no model" and only notify.
                return await fallbackNotify(event, .modelUnavailable)
            }
            guard triageBudget.remaining > 0 else {
                return await deferEvent(event, .triageBudget, until: now + triageBudget.secondsUntilRefill(now: now))
            }
            do {
                triage = try await triageModel.triage(event.signal)
                triageBudget.charge(triage.tokens, now: clock())
            } catch {
                triage = .fallback(String(describing: error))
            }
            cacheTriage(triage, for: event.seq)
        }

        if triage.isFallback {
            return await fallbackNotify(event, .modelUnavailable)
        }

        switch triage.intent {
        case .ignore:
            do { try await log.complete(event.seq) } catch { return .storageFailure(String(describing: error)) }
            triageCache[event.seq] = nil
            return .ignored(seq: event.seq)
        case .notifyUser, .addReminder:
            return await runLocal(event, intent: triage.intent)
        case .draftReply, .sendMessage, .purchase:
            return await runCloud(event, triage: triage, energy: energy)
        }
    }

    // MARK: - Stages

    private func runLocal(_ event: LoggedEvent, intent: ProposedIntent) async -> StepOutcome {
        let action: PlannedAction
        switch intent {
        case .addReminder:
            action = PlannedAction(tool: "reminders.create", arguments: ["title": event.signal.title], summary: "Remind me: \(event.signal.title)")
        default:
            action = PlannedAction(tool: "notifications.post", arguments: ["title": event.signal.title], summary: "Notify: \(event.signal.title)")
        }
        return await route(event, action: action, egressed: nil)
    }

    private func runCloud(_ event: LoggedEvent, triage: TriageResult, energy: EnergyState) async -> StepOutcome {
        let now = clock()
        let decision = policy.evaluate(event.signal, destination: config.destination, consent: consent, now: now)

        let ticket: EgressTicket
        switch decision {
        case .needsConsent(let categories):
            do { try await log.park(event.seq) } catch { return .storageFailure(String(describing: error)) }
            // Consent may have been granted while we were suspended in `park`.
            let after = clock()
            if categories.allSatisfy({ consent.isGranted($0, to: config.destination, now: after) }) {
                do { try await log.release(event.seq, notBefore: after) } catch { return .storageFailure(String(describing: error)) }
                return .deferred(seq: event.seq, reason: .requeued, until: after)
            }
            awaitingConsent[event.seq] = categories
            metrics.consentPrompts = Saturating.add(metrics.consentPrompts, 1)
            return .awaitingConsent(seq: event.seq, categories: categories)
        case .localOnly(let reason, let findings):
            if reason == .leakDetected { metrics.leaksBlocked = Saturating.add(metrics.leaksBlocked, 1) }
            return await fallbackNotify(event, .egress(reason, findings: findings))
        case .allow(let t):
            ticket = t
        }

        guard config.energyPolicy.allowsCloud(energy, urgency: triage.urgency) else {
            return await deferEvent(event, .energy, now: now)
        }

        let tools = catalog.disclose(for: triage.intent)
        let toolTokens = tools.reduce(0) { Saturating.add($0, $1.schemaTokens) }
        let cost = Saturating.add(toolTokens, ticket.byteCount / 4)
        guard cost <= cloudBudget.capacity else { return await fallbackNotify(event, .exceedsStageBudget) }
        guard cloudBudget.consume(cost, now: now) else {
            return await deferEvent(event, .cloudBudget, until: now + cloudBudget.secondsUntilRefill(now: now))
        }
        let chargedWindow = cloudBudget.windowStart

        let planned: PlannedAction?
        do {
            planned = try await planner.plan(ticket, intent: triage.intent, tools: tools)
        } catch CloudPlannerError.offline {
            // Nothing left the device: give the tokens back and don't count an attempt.
            cloudBudget.refund(cost, chargedInWindowStartingAt: chargedWindow)
            return await deferEvent(event, .offline, now: clock())
        } catch {
            recordEgress(ticket, toolTokens: toolTokens)
            return await retryOrFallback(event)
        }
        recordEgress(ticket, toolTokens: toolTokens)

        guard let action = planned else { return await fallbackNotify(event, .plannerDeclined) }
        guard tools.contains(where: { $0.name == action.tool }) else {
            return await fallbackNotify(event, .undisclosedTool(action.tool))
        }
        return await route(event, action: action, egressed: ticket)
    }

    /// Bounded by the log's capacity. An entry can outlive its event (the log may shed a
    /// deferred event), so the lowest sequence numbers are evicted first; evicting a live entry
    /// only costs a re-triage.
    private func cacheTriage(_ result: TriageResult, for seq: UInt64) {
        triageCache[seq] = result
        while triageCache.count > log.config.capacity, let oldest = triageCache.keys.min() {
            triageCache[oldest] = nil
        }
    }

    var triageCacheCount: Int { triageCache.count }

    private func recordEgress(_ ticket: EgressTicket, toolTokens: Int) {
        metrics.ticketsIssued = Saturating.add(metrics.ticketsIssued, 1)
        metrics.bytesEgressed = Saturating.add(metrics.bytesEgressed, ticket.byteCount)
        metrics.disclosedSchemaTokens = Saturating.add(metrics.disclosedSchemaTokens, toolTokens)
        metrics.eagerSchemaTokens = Saturating.add(metrics.eagerSchemaTokens, catalog.eagerSchemaTokens)
        recentEgress.append(ticket)
        if recentEgress.count > config.maxRecentEgress { recentEgress.removeFirst(recentEgress.count - config.maxRecentEgress) }
    }

    /// Consequential actions park for approval; everything else executes.
    private func route(_ event: LoggedEvent, action: PlannedAction, egressed: EgressTicket?) async -> StepOutcome {
        let risk = catalog.tool(named: action.tool)?.risk ?? .consequential // unknown tools are treated as dangerous
        guard risk == .consequential else {
            return await perform(event, action: action, egressed: egressed) {
                .executed(seq: event.seq, action: action, egressed: egressed)
            }
        }
        do { try await log.park(event.seq) } catch { return .storageFailure(String(describing: error)) }
        let id = nextApprovalID
        nextApprovalID = nextApprovalID == UInt64.max ? 1 : nextApprovalID + 1
        let request = ApprovalRequest(id: id, eventSeq: event.seq, action: action, digest: action.digest,
                                      expiresAt: clock() + config.approvalTTL, egressed: egressed)
        approvals[id] = request
        metrics.approvalsRequested = Saturating.add(metrics.approvalsRequested, 1)
        return .awaitingApproval(request)
    }

    /// Execute → journal → complete, with idempotency and bounded retries.
    private func perform(_ event: LoggedEvent, action: PlannedAction, egressed: EgressTicket?,
                         success: () -> StepOutcome) async -> StepOutcome {
        let key = ActionJournal.key(signalID: event.signal.id)
        if journal.contains(key) {
            metrics.duplicatesSuppressed = Saturating.add(metrics.duplicatesSuppressed, 1)
            do { try await log.complete(event.seq) } catch { return .storageFailure(String(describing: error)) }
            triageCache[event.seq] = nil
            return .duplicateSuppressed(seq: event.seq)
        }
        do {
            try await executor.execute(action, idempotencyKey: key)
        } catch {
            return await retryOrDeadLetter(event)
        }
        // Recorded in the same synchronous stretch as the executor's return: nothing can run between.
        journal.record(key)
        metrics.executed = Saturating.add(metrics.executed, 1)
        do { try await log.complete(event.seq) } catch { return .storageFailure(String(describing: error)) }
        triageCache[event.seq] = nil
        return success()
    }

    private func fallbackNotify(_ event: LoggedEvent, _ reason: LocalReason) async -> StepOutcome {
        let action = PlannedAction(tool: "notifications.post", arguments: ["title": event.signal.title],
                                   summary: "Notify: \(event.signal.title)")
        return await perform(event, action: action, egressed: nil) {
            metrics.notifiedLocally = Saturating.add(metrics.notifiedLocally, 1)
            return .notifiedLocally(seq: event.seq, reason: reason)
        }
    }

    private func retryOrFallback(_ event: LoggedEvent) async -> StepOutcome {
        let attempts: Int
        do { attempts = try await log.recordFailure(event.seq) } catch { return .storageFailure(String(describing: error)) }
        if attempts >= config.maxAttempts { return await fallbackNotify(event, .cloudRetriesExhausted) }
        let at = clock() + config.backoff(afterAttempt: attempts)
        do { try await log.release(event.seq, notBefore: at) } catch { return .storageFailure(String(describing: error)) }
        return .retryScheduled(seq: event.seq, attempt: attempts, at: at)
    }

    private func retryOrDeadLetter(_ event: LoggedEvent) async -> StepOutcome {
        let attempts: Int
        do { attempts = try await log.recordFailure(event.seq) } catch { return .storageFailure(String(describing: error)) }
        if attempts >= config.maxAttempts {
            do { try await log.deadLetter(event.seq) } catch { return .storageFailure(String(describing: error)) }
            triageCache[event.seq] = nil
            return .deadLettered(seq: event.seq)
        }
        let at = clock() + config.backoff(afterAttempt: attempts)
        do { try await log.release(event.seq, notBefore: at) } catch { return .storageFailure(String(describing: error)) }
        return .retryScheduled(seq: event.seq, attempt: attempts, at: at)
    }

    private func deferEvent(_ event: LoggedEvent, _ reason: DeferReason, now: Double) async -> StepOutcome {
        await deferEvent(event, reason, until: now + config.deferInterval)
    }

    private func deferEvent(_ event: LoggedEvent, _ reason: DeferReason, until: Double) async -> StepOutcome {
        do { try await log.release(event.seq, notBefore: until) } catch { return .storageFailure(String(describing: error)) }
        return .deferred(seq: event.seq, reason: reason, until: until)
    }

    /// Returns the first expired approval's event to the queue (one per step keeps steps bounded).
    private func expireApprovals(now: Double) async -> StepOutcome? {
        guard let expired = approvals.values.filter({ $0.expiresAt <= now }).min(by: { $0.id < $1.id }) else { return nil }
        approvals[expired.id] = nil
        do {
            try await log.release(expired.eventSeq, notBefore: now)
        } catch {
            approvals[expired.id] = expired // retried on the next step
            return .storageFailure(String(describing: error))
        }
        return .approvalExpired(seq: expired.eventSeq)
    }
}
