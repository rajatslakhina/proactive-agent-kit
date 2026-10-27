import Foundation

/// Lifecycle of an event in the durable log.
///
/// - `pending`: claimable once `notBefore` has passed.
/// - `inFlight`: claimed by the loop; exactly one stage owns it.
/// - `parked`: waiting on a human (consent or approval). Not claimable.
///
/// On recovery after a crash, `inFlight` and `parked` both return to `pending`: the loop
/// re-triages from scratch rather than trusting a half-finished decision. That makes
/// processing at-least-once; the `ActionJournal` is what keeps side effects from repeating.
public enum EventState: String, Codable, Sendable, Hashable {
    case pending, inFlight, parked
}

public struct LoggedEvent: Codable, Sendable, Hashable, Identifiable {
    public let seq: UInt64
    public let signal: Signal
    public internal(set) var state: EventState
    public internal(set) var attempts: Int
    public internal(set) var notBefore: Double
    public var id: UInt64 { seq }
}

public struct EventLogConfig: Sendable, Hashable {
    /// Maximum live (pending + inFlight + parked) events. The log never grows past this.
    public let capacity: Int
    /// Maximum live events per source: a notification storm hits its own quota first.
    public let perSourceQuota: Int
    /// How many recently seen signal ids are remembered for de-duplication.
    public let dedupMemory: Int
    /// Bounded dead-letter history.
    public let maxDeadLetters: Int

    public init(capacity: Int = 64, perSourceQuota: Int = 24, dedupMemory: Int = 256, maxDeadLetters: Int = 32) {
        // Zero or negative limits would make the log unusable or trap on index math; normalise.
        self.capacity = Swift.max(1, capacity)
        self.perSourceQuota = Swift.max(1, Swift.min(perSourceQuota, self.capacity))
        self.dedupMemory = Swift.max(1, dedupMemory)
        self.maxDeadLetters = Swift.max(1, maxDeadLetters)
    }
}

public enum AppendRejection: Sendable, Hashable {
    case sourceQuota(SignalSource)
    case full
    case sequenceExhausted
}

public enum AppendOutcome: Sendable, Hashable {
    case appended(seq: UInt64)
    /// Appended, but the log was full so the oldest pending event of the busiest source was shed.
    case appendedShedding(seq: UInt64, shed: UInt64)
    case duplicate
    case rejected(AppendRejection)
}

public struct DeadLetter: Codable, Sendable, Hashable {
    public enum Reason: String, Codable, Sendable { case shedUnderPressure, retriesExhausted }
    public let event: LoggedEvent
    public let reason: Reason
}

/// The persisted form of the log. Plain data so any storage can hold it.
public struct EventLogSnapshot: Codable, Sendable, Hashable {
    public var nextSeq: UInt64 = 1
    public var live: [LoggedEvent] = []
    public var seenIDs: [String] = []
    public var deadLetters: [DeadLetter] = []
    public var completed: Int = 0
}

public protocol EventLogStorage: Sendable {
    func load() throws -> EventLogSnapshot?
    func save(_ snapshot: EventLogSnapshot) throws
}

public enum EventLogError: Error, Sendable, Hashable {
    case storage(String)
    case unknownSequence(UInt64)
    case invalidTransition(UInt64, from: EventState)
}

/// A durable, bounded, de-duplicating event log with per-source backpressure.
///
/// Every mutation is computed on a copy, persisted, and only then made visible
/// (write-then-publish). If the save fails the in-memory state is unchanged, so memory
/// and disk can never disagree about what was accepted.
public actor EventLog {
    public let config: EventLogConfig
    private let storage: any EventLogStorage
    private var state: EventLogSnapshot
    private var seen: Set<String>

    public init(config: EventLogConfig = EventLogConfig(), storage: any EventLogStorage) throws {
        self.config = config
        self.storage = storage
        var loaded: EventLogSnapshot
        do { loaded = try storage.load() ?? EventLogSnapshot() } catch { throw EventLogError.storage(String(describing: error)) }
        // Crash recovery: nothing is in flight in a fresh process.
        for i in loaded.live.indices where loaded.live[i].state != .pending {
            loaded.live[i].state = .pending
        }
        loaded.live.sort { $0.seq < $1.seq }
        state = loaded
        seen = Set(loaded.seenIDs)
    }

    // MARK: Reads

    public func snapshot() -> EventLogSnapshot { state }
    public var liveCount: Int { state.live.count }
    public func event(_ seq: UInt64) -> LoggedEvent? { state.live.first { $0.seq == seq } }

    // MARK: Mutations

    public func append(_ signal: Signal) throws -> AppendOutcome {
        if seen.contains(signal.id) || state.live.contains(where: { $0.signal.id == signal.id }) {
            return .duplicate
        }
        if state.nextSeq == UInt64.max { return .rejected(.sequenceExhausted) }
        let fromSource = state.live.lazy.filter { $0.signal.source == signal.source }.count
        if fromSource >= config.perSourceQuota { return .rejected(.sourceQuota(signal.source)) }

        var shedSeq: UInt64?
        var next = state
        if next.live.count >= config.capacity {
            guard let victimIndex = Self.sheddingVictim(in: next.live) else { return .rejected(.full) }
            let victim = next.live.remove(at: victimIndex)
            shedSeq = victim.seq
            Self.pushDeadLetter(DeadLetter(event: victim, reason: .shedUnderPressure), into: &next, limit: config.maxDeadLetters)
            // A shed event was never processed: forget its id so a redelivery can re-enter.
            next.seenIDs.removeAll { $0 == victim.signal.id }
        }

        let seq = next.nextSeq
        next.nextSeq = seq + 1 // cannot overflow: guarded against .max above
        next.live.append(LoggedEvent(seq: seq, signal: signal, state: .pending, attempts: 0, notBefore: signal.receivedAt))
        next.seenIDs.append(signal.id)
        if next.seenIDs.count > config.dedupMemory {
            next.seenIDs.removeFirst(next.seenIDs.count - config.dedupMemory)
        }
        try persist(next)
        if let shedSeq { return .appendedShedding(seq: seq, shed: shedSeq) }
        return .appended(seq: seq)
    }

    /// Claims the oldest pending event whose `notBefore` has passed. FIFO by sequence, but a
    /// deferred event never blocks the ones behind it (no head-of-line blocking).
    public func claimNext(now: Double) throws -> LoggedEvent? {
        guard let i = state.live.firstIndex(where: { $0.state == .pending && $0.notBefore <= now }) else { return nil }
        var next = state
        next.live[i].state = .inFlight
        let claimed = next.live[i]
        try persist(next)
        return claimed
    }

    public func park(_ seq: UInt64) throws {
        try transition(seq, allowed: [.inFlight]) { $0.state = .parked }
    }

    /// Returns an event to `pending` without counting an attempt (deferral, consent granted).
    public func release(_ seq: UInt64, notBefore: Double) throws {
        try transition(seq, allowed: [.inFlight, .parked]) {
            $0.state = .pending
            $0.notBefore = notBefore
        }
    }

    /// Counts a failed attempt and returns the new attempt count. The event stays in flight;
    /// the caller decides between `release` (retry), `complete` (fallback) and `deadLetter`.
    @discardableResult
    public func recordFailure(_ seq: UInt64) throws -> Int {
        var attempts = 0
        // `.parked` is allowed: an approved action can fail after the human said yes.
        try transition(seq, allowed: [.inFlight, .parked]) {
            $0.attempts = Saturating.add($0.attempts, 1)
            attempts = $0.attempts
        }
        return attempts
    }

    public func complete(_ seq: UInt64) throws {
        guard let i = state.live.firstIndex(where: { $0.seq == seq }) else { throw EventLogError.unknownSequence(seq) }
        var next = state
        next.live.remove(at: i)
        next.completed = Saturating.add(next.completed, 1)
        try persist(next)
    }

    public func deadLetter(_ seq: UInt64) throws {
        guard let i = state.live.firstIndex(where: { $0.seq == seq }) else { throw EventLogError.unknownSequence(seq) }
        var next = state
        let event = next.live.remove(at: i)
        Self.pushDeadLetter(DeadLetter(event: event, reason: .retriesExhausted), into: &next, limit: config.maxDeadLetters)
        try persist(next)
    }

    // MARK: Internals

    private func transition(_ seq: UInt64, allowed: Set<EventState>, _ body: (inout LoggedEvent) -> Void) throws {
        guard let i = state.live.firstIndex(where: { $0.seq == seq }) else { throw EventLogError.unknownSequence(seq) }
        let current = state.live[i].state
        guard allowed.contains(current) else { throw EventLogError.invalidTransition(seq, from: current) }
        var next = state
        body(&next.live[i])
        try persist(next)
    }

    private func persist(_ next: EventLogSnapshot) throws {
        do { try storage.save(next) } catch { throw EventLogError.storage(String(describing: error)) }
        state = next
        seen = Set(next.seenIDs)
    }

    /// The oldest *pending* event from the source holding the most live events. In-flight and
    /// parked events are never shed: a human may be looking at them.
    static func sheddingVictim(in live: [LoggedEvent]) -> Int? {
        var counts: [SignalSource: Int] = [:]
        for e in live { counts[e.signal.source, default: 0] += 1 }
        let ranked = counts.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key.rawValue < rhs.key.rawValue
        }
        for (source, _) in ranked {
            if let i = live.firstIndex(where: { $0.signal.source == source && $0.state == .pending }) { return i }
        }
        return nil
    }

    static func pushDeadLetter(_ letter: DeadLetter, into snapshot: inout EventLogSnapshot, limit: Int) {
        snapshot.deadLetters.append(letter)
        if snapshot.deadLetters.count > limit {
            snapshot.deadLetters.removeFirst(snapshot.deadLetters.count - limit)
        }
    }
}

// MARK: - Storage implementations

/// Volatile storage for tests and previews.
public final class InMemoryEventLogStorage: EventLogStorage, @unchecked Sendable {
    // @unchecked: all mutable state is guarded by `lock`.
    private let lock = NSLock()
    private var stored: EventLogSnapshot?

    public init(_ initial: EventLogSnapshot? = nil) { stored = initial }

    public func load() throws -> EventLogSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    public func save(_ snapshot: EventLogSnapshot) throws {
        lock.lock(); defer { lock.unlock() }
        stored = snapshot
    }
}

/// JSON file storage with atomic replace. A corrupt file throws on load instead of being
/// silently replaced: losing the log would mean silently dropping user-visible work.
public struct FileEventLogStorage: EventLogStorage {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> EventLogSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(EventLogSnapshot.self, from: data)
    }

    public func save(_ snapshot: EventLogSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }
}
