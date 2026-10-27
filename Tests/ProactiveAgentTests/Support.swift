import Dispatch
import Foundation
@testable import ProactiveAgent

struct StorageFailure: Error {}

/// Storage that fails every save once `failAfter` successful saves have happened.
final class FlakyStorage: EventLogStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: EventLogSnapshot?
    private var saves = 0
    var failAfter: Int

    init(failAfter: Int = .max) { self.failAfter = failAfter }

    func load() throws -> EventLogSnapshot? { lock.lock(); defer { lock.unlock() }; return stored }

    func save(_ snapshot: EventLogSnapshot) throws {
        lock.lock(); defer { lock.unlock() }
        guard saves < failAfter else { throw StorageFailure() }
        saves += 1
        stored = snapshot
    }

    var saveCount: Int { lock.lock(); defer { lock.unlock() }; return saves }
}

/// An executor that suspends inside `execute` until the test opens the gate.
final class GatedExecutor: ActionExecutor, @unchecked Sendable {
    let gate = Gate()
    let executed = Locked<[PlannedAction]>([])
    func execute(_ action: PlannedAction, idempotencyKey: StableDigest) async throws {
        await gate.wait()
        executed.mutate { $0.append(action) }
    }
}

/// Storage whose `blockOnSave`-th save blocks the calling thread until `unblock()`.
/// Used to hold the EventLog actor inside `park` while another call runs on the AgentLoop.
final class BlockingStorage: EventLogStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: EventLogSnapshot?
    private var saves = 0
    private let blockOnSave: Int
    private let semaphore = DispatchSemaphore(value: 0)
    let isBlocked = Locked(false)

    init(blockOnSave: Int) { self.blockOnSave = blockOnSave }

    func load() throws -> EventLogSnapshot? { lock.lock(); defer { lock.unlock() }; return stored }

    func save(_ snapshot: EventLogSnapshot) throws {
        lock.lock()
        saves += 1
        let shouldBlock = saves == blockOnSave
        stored = snapshot
        lock.unlock()
        if shouldBlock {
            isBlocked.set(true)
            semaphore.wait()
        }
    }

    func unblock() { semaphore.signal() }
}

/// Polls until `box` holds a value or `seconds` elapse, then returns whatever it holds.
/// A correct implementation is observed answering on its own (before a test opens a gate);
/// a broken one that blocks on the gate makes the test fail instead of hang, and slow CI
/// runners get seconds rather than a fixed 50 ms.
func waitForValue<T: Sendable>(_ box: Locked<T?>, upTo seconds: Double = 10) async throws -> T? {
    let deadline = Date().addingTimeInterval(seconds)
    while box.get() == nil && Date() < deadline {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    return box.get()
}

/// Counts how often the model actually ran.
struct CountingTriage: TriageModel {
    let calls = Locked(0)
    func triage(_ signal: Signal) async throws -> TriageResult {
        calls.mutate { $0 += 1 }
        return try await HeuristicTriageModel().triage(signal)
    }
}

struct UnavailableTriage: TriageModel {
    func triage(_ signal: Signal) async throws -> TriageResult { throw TriageModelError.unavailable }
}

/// Classifies everything as shareable: a deliberately broken classifier.
struct PermissiveClassifier: EgressClassifier {
    func categories(for field: SignalField) -> Set<DataCategory> { [.general] }
}

/// A triage model that suspends until the test releases it.
actor Gate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var entered = false
    func wait() async {
        entered = true
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    /// Releases every waiter, and lets later callers straight through.
    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}

struct GatedTriage: TriageModel {
    let gate: Gate
    func triage(_ signal: Signal) async throws -> TriageResult {
        await gate.wait()
        return TriageResult(intent: .notifyUser, urgency: .low, rationale: "gated")
    }
}

enum Fixtures {
    static func notification(_ id: String, _ title: String, at t: Double = 0, fields: [SignalField] = []) -> Signal {
        Signal(id: id, source: .notification, receivedAt: t, title: title, fields: fields)
    }

    static let lateMessage = Signal(id: "msg-1", source: .notification, receivedAt: 0,
                                    title: "Sam: running late? can you reply",
                                    fields: [SignalField("sender", "sam@example.com")])
    static let otp = Signal(id: "otp-1", source: .notification, receivedAt: 0,
                            title: "Your verification code is 482913")
    static let reorder = Signal(id: "buy-1", source: .appIntent, receivedAt: 0,
                                title: "Running low on coffee filters, reorder?",
                                fields: [SignalField("item", "coffee filters")])
    static let promo = notification("promo-1", "Weekend promo: 20% off, unsubscribe anytime")
}

struct Harness {
    let clock: SimulatedClock
    let storage: FlakyStorage
    let planner = SimulatedCloudPlanner()
    let executor = RecordingExecutor()
    let log: EventLog
    let loop: AgentLoop

    init(triage: any TriageModel = HeuristicTriageModel(),
         policy: EgressPolicy = EgressPolicy(),
         triageTokensPerHour: Int = 4_000,
         cloudTokensPerHour: Int = 6_000,
         journal: ActionJournal = ActionJournal(),
         storage: FlakyStorage? = nil,
         logConfig: EventLogConfig = EventLogConfig(),
         clockStart: Double = 1_000,
         config: AgentLoopConfig = AgentLoopConfig()) throws {
        self.clock = SimulatedClock(start: clockStart)
        self.storage = storage ?? FlakyStorage()
        log = try EventLog(config: logConfig, storage: self.storage)
        loop = AgentLoop(log: log, triage: triage, policy: policy, planner: planner, executor: executor,
                         triageTokensPerHour: triageTokensPerHour, cloudTokensPerHour: cloudTokensPerHour, journal: journal, config: config, clock: clock.clock)
    }
}
