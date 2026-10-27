#if canImport(SwiftUI)
import Combine
import Foundation
import ProactiveAgent
import SwiftUI

/// One line in the console's timeline.
public struct TimelineEntry: Identifiable, Hashable, Sendable {
    public let id: Int
    public let time: Double
    public let description: OutcomeDescription
}

/// Drives the real `AgentLoop` with simulated collaborators and switchable faults.
/// Main-actor isolated; every loop call is awaited, so the UI never blocks on the agent.
@MainActor
public final class AgentConsoleModel: ObservableObject {
    @Published public private(set) var live: [LoggedEvent] = []
    @Published public private(set) var timeline: [TimelineEntry] = []
    @Published public private(set) var status: AgentStatus?
    @Published public private(set) var now: Double = 0
    @Published public private(set) var isWorking = false
    @Published public private(set) var setupError: String?

    @Published public var lowPowerMode = false
    @Published public var offline = false { didSet { planner.faults.mutate { $0.offline = offline } } }
    @Published public var classifierBug = false { didSet { classifier.broken.set(classifierBug) } }
    @Published public var rogueRequests = false { didSet { planner.faults.mutate { $0.rogue = rogueRequests } } }

    public let signals: [Signal]
    /// Starts after the scenario's last `receivedAt`, so every delivered signal is claimable at once.
    private static let startTime: Double = 60
    private var clock = SimulatedClock(start: AgentConsoleModel.startTime)
    private let planner = SimulatedCloudPlanner()
    private let executor = RecordingExecutor()
    private let classifier = FaultInjectableClassifier()
    private var log: EventLog?
    private var loop: AgentLoop?
    private var nextEntryID = 0

    public init(signals: [Signal]) {
        self.signals = signals
        rebuild()
    }

    public var energy: EnergyState { EnergyState(batteryLevel: 0.8, lowPowerMode: lowPowerMode) }


    // MARK: Intents

    public func reset() {
        guard !isWorking else { return }
        clock = SimulatedClock(start: Self.startTime)
        timeline = []
        live = []
        status = nil
        rebuild()
    }

    public func deliverSignals() async {
        guard let log, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        for signal in signals {
            do {
                let outcome = try await log.append(signal)
                record(outcome.presentation)
            } catch {
                record(OutcomeDescription(headline: "Log write failed", detail: String(describing: error), tone: .failed))
            }
        }
        await refresh()
    }

    public func step() async {
        guard let loop, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let outcome = await loop.step(energy: energy)
        record(outcome.presentation)
        await refresh()
    }

    /// Steps until the loop reports idle. Bounded so a pathological configuration can't spin.
    public func runUntilIdle() async {
        guard let loop, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        var steps = 0
        for _ in 0..<64 {
            let outcome = await loop.step(energy: energy)
            if outcome == .idle || outcome == .busy { break }
            record(outcome.presentation)
            steps += 1
        }
        if steps == 0 { record(StepOutcome.idle.presentation) }
        await refresh()
    }

    public func advance(minutes: Double) async {
        guard !isWorking else { return }
        clock.advance(by: minutes * 60)
        await refresh()
    }

    public func approve(_ request: ApprovalRequest) async {
        guard let loop, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        record((await loop.approve(request.id, digest: request.digest)).presentation)
        await refresh()
    }

    public func reject(_ request: ApprovalRequest) async {
        guard let loop, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        record((await loop.reject(request.id)).presentation)
        await refresh()
    }

    public func allow(_ categories: Set<DataCategory>) async {
        guard let loop, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let released = await loop.grantConsent(categories)
        let kinds = categories.map(\.rawValue).sorted().joined(separator: ", ")
        record(OutcomeDescription(headline: "Consent granted: \(kinds)",
                                  detail: released.isEmpty ? "nothing was waiting" : "requeued #\(released.map(String.init).joined(separator: ", #"))",
                                  tone: .done))
        await refresh()
    }

    // MARK: Internals

    private func rebuild() {
        planner.faults.set(SimulatedCloudPlanner.Faults())
        planner.faults.mutate {
            $0.offline = offline
            $0.rogue = rogueRequests
        }
        executor.executed.set([])
        planner.received.set([])
        do {
            let log = try EventLog(config: EventLogConfig(capacity: 32, perSourceQuota: 12), storage: InMemoryEventLogStorage())
            self.log = log
            self.loop = AgentLoop(log: log,
                                  policy: EgressPolicy(classifier: classifier),
                                  planner: planner,
                                  executor: executor,
                                  config: AgentLoopConfig(destination: "cloud-model"),
                                  clock: clock.clock)
            setupError = nil
        } catch {
            log = nil
            loop = nil
            setupError = String(describing: error)
        }
    }

    private func refresh() async {
        now = clock.read()
        if let log { live = await log.snapshot().live }
        if let loop { status = await loop.status() }
    }

    private func record(_ description: OutcomeDescription) {
        nextEntryID = nextEntryID == Int.max ? 0 : nextEntryID + 1
        timeline.insert(TimelineEntry(id: nextEntryID, time: clock.read(), description: description), at: 0)
        if timeline.count > 200 { timeline.removeLast(timeline.count - 200) }
    }
}
#endif
