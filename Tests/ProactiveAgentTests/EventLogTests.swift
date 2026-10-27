import Foundation
import XCTest
@testable import ProactiveAgent

final class EventLogTests: XCTestCase {
    func sig(_ id: String, _ source: SignalSource = .notification, at t: Double = 0) -> Signal {
        Signal(id: id, source: source, receivedAt: t, title: id)
    }

    func testClaimIsFIFOAndDuplicatesAreDroppedEvenAfterCompletion() async throws {
        let log = try EventLog(storage: InMemoryEventLogStorage())
        let first = try await log.append(sig("a"))
        let second = try await log.append(sig("b"))
        XCTAssertEqual(first, .appended(seq: 1))
        XCTAssertEqual(second, .appended(seq: 2))
        let dupLive = try await log.append(sig("a"))
        XCTAssertEqual(dupLive, .duplicate)

        let claimed = try await log.claimNext(now: 0)
        XCTAssertEqual(claimed?.signal.id, "a")
        try await log.complete(1)
        let dupDone = try await log.append(sig("a"))
        XCTAssertEqual(dupDone, .duplicate, "a completed signal redelivered must not re-enter")
    }

    func testPerSourceQuotaIsolatesANoisySource() async throws {
        let log = try EventLog(config: EventLogConfig(capacity: 10, perSourceQuota: 2), storage: InMemoryEventLogStorage())
        _ = try await log.append(sig("n1"))
        _ = try await log.append(sig("n2"))
        let third = try await log.append(sig("n3"))
        XCTAssertEqual(third, .rejected(.sourceQuota(.notification)))
        let calendar = try await log.append(sig("c1", .calendar))
        XCTAssertEqual(calendar, .appended(seq: 3), "another source is unaffected by the noisy one")
    }

    func testCapacityShedsOldestPendingOfBusiestSourceAndForgetsItsID() async throws {
        let log = try EventLog(config: EventLogConfig(capacity: 3, perSourceQuota: 3), storage: InMemoryEventLogStorage())
        _ = try await log.append(sig("n1"))            // seq 1
        _ = try await log.append(sig("c1", .calendar)) // seq 2
        _ = try await log.append(sig("n2"))            // seq 3
        let outcome = try await log.append(sig("c2", .calendar))
        XCTAssertEqual(outcome, .appendedShedding(seq: 4, shed: 1), "notification is the busiest source; its oldest pending is shed")
        let letters = await log.snapshot().deadLetters
        XCTAssertEqual(letters.map(\.reason), [.shedUnderPressure])
        XCTAssertEqual(letters.first?.event.signal.id, "n1")
        // n1 was never processed, so a redelivery is accepted again (after making room).
        _ = try await log.claimNext(now: 0)
        try await log.complete(2)
        let redelivered = try await log.append(sig("n1"))
        XCTAssertEqual(redelivered, .appended(seq: 5))
    }

    func testShedsFromTheBusiestSourceEvenWhenAnotherSourceHoldsTheOldestEvent() async throws {
        let log = try EventLog(config: EventLogConfig(capacity: 3, perSourceQuota: 3), storage: InMemoryEventLogStorage())
        _ = try await log.append(sig("c1", .calendar)) // seq 1: oldest overall
        _ = try await log.append(sig("n1"))            // seq 2
        _ = try await log.append(sig("n2"))            // seq 3
        let outcome = try await log.append(sig("a1", .appIntent))
        XCTAssertEqual(outcome, .appendedShedding(seq: 4, shed: 2), "notification is busiest; the calendar event survives")
    }

    func testDedupMemoryIsTrimmedToItsLimit() async throws {
        let log = try EventLog(config: EventLogConfig(capacity: 10, dedupMemory: 2), storage: InMemoryEventLogStorage())
        for id in ["a", "b", "c"] {
            _ = try await log.append(sig(id))
            let e = try await log.claimNext(now: 0)
            try await log.complete(try XCTUnwrap(e).seq)
        }
        let seen = await log.snapshot().seenIDs
        XCTAssertEqual(seen, ["b", "c"])
        let again = try await log.append(sig("a"))
        XCTAssertEqual(again, .appended(seq: 4), "'a' fell out of the window, so it is accepted again")
        let dup = try await log.append(sig("c"))
        XCTAssertEqual(dup, .duplicate)
    }

    func testInFlightEventsAreNeverShedAndAFullLogRejects() async throws {
        let log = try EventLog(config: EventLogConfig(capacity: 2, perSourceQuota: 2), storage: InMemoryEventLogStorage())
        _ = try await log.append(sig("a"))
        _ = try await log.append(sig("b", .calendar))
        _ = try await log.claimNext(now: 0)
        _ = try await log.claimNext(now: 0)
        let outcome = try await log.append(sig("c", .appIntent))
        XCTAssertEqual(outcome, .rejected(.full))
        let count = await log.liveCount
        XCTAssertEqual(count, 2)
    }

    func testDeferredEventDoesNotBlockLaterOnes() async throws {
        let log = try EventLog(storage: InMemoryEventLogStorage())
        _ = try await log.append(sig("a"))
        _ = try await log.append(sig("b"))
        let a = try await log.claimNext(now: 0)
        try await log.release(try XCTUnwrap(a).seq, notBefore: 100)
        let next = try await log.claimNext(now: 1)
        XCTAssertEqual(next?.signal.id, "b")
        let none = try await log.claimNext(now: 50)
        XCTAssertNil(none)
        let later = try await log.claimNext(now: 100)
        XCTAssertEqual(later?.signal.id, "a")
    }

    func testRecoveryReturnsInFlightAndParkedToPending() async throws {
        let storage = InMemoryEventLogStorage()
        do {
            let log = try EventLog(storage: storage)
            _ = try await log.append(sig("a"))
            _ = try await log.append(sig("b"))
            _ = try await log.claimNext(now: 0)
            let b = try await log.claimNext(now: 0)
            try await log.park(try XCTUnwrap(b).seq)
        }
        let reopened = try EventLog(storage: storage)
        let states = await reopened.snapshot().live.map(\.state)
        XCTAssertEqual(states, [.pending, .pending])
    }

    func testFailedSaveLeavesStateUnchanged() async throws {
        let storage = FlakyStorage(failAfter: 1)
        let log = try EventLog(storage: storage)
        _ = try await log.append(sig("a"))
        do {
            _ = try await log.append(sig("b"))
            XCTFail("expected a storage error")
        } catch EventLogError.storage {}
        let ids = await log.snapshot().live.map(\.signal.id)
        XCTAssertEqual(ids, ["a"], "memory must never get ahead of disk")
        // And "b" was not remembered as seen: it can be appended once storage recovers.
        storage.failAfter = .max
        let retry = try await log.append(sig("b"))
        XCTAssertEqual(retry, .appended(seq: 2))
    }

    func testFailedTransitionSaveLeavesStateUnchanged() async throws {
        let storage = FlakyStorage()
        let log = try EventLog(storage: storage)
        _ = try await log.append(sig("a"))
        _ = try await log.claimNext(now: 0)
        storage.failAfter = storage.saveCount
        do { try await log.park(1); XCTFail("expected a storage error") } catch EventLogError.storage {}
        let state = await log.event(1)?.state
        XCTAssertEqual(state, .inFlight, "memory must not move ahead of disk on a transition either")
    }

    func testParkedEventsAreNeverShed() async throws {
        let log = try EventLog(config: EventLogConfig(capacity: 2, perSourceQuota: 2), storage: InMemoryEventLogStorage())
        _ = try await log.append(sig("n1"))
        _ = try await log.append(sig("n2"))
        _ = try await log.claimNext(now: 0)
        try await log.park(1)
        let outcome = try await log.append(sig("c1", .calendar))
        XCTAssertEqual(outcome, .appendedShedding(seq: 3, shed: 2), "the pending n2 goes, the parked n1 stays")
        _ = try await log.claimNext(now: 0)
        let full = try await log.append(sig("a1", .appIntent))
        XCTAssertEqual(full, .rejected(.full), "parked + in-flight only: nothing sheddable")
    }

    func testDecodedJournalIsNormalised() throws {
        let json = #"{"limit":0,"order":[{"value":1},{"value":1},{"value":2}]}"#
        let j = try JSONDecoder().decode(ActionJournal.self, from: Data(json.utf8))
        XCTAssertEqual(j.limit, 1)
        XCTAssertEqual(j.count, 1)
        XCTAssertTrue(j.contains(StableDigest(value: 2)))
    }

    func testInvalidTransitionsThrow() async throws {
        let log = try EventLog(storage: InMemoryEventLogStorage())
        _ = try await log.append(sig("a"))
        do { try await log.park(1); XCTFail("pending cannot be parked") } catch EventLogError.invalidTransition(1, from: .pending) {}
        do { try await log.complete(99); XCTFail("unknown seq") } catch EventLogError.unknownSequence(99) {}
    }

    func testConfigNormalisesNonsenseLimits() {
        let c = EventLogConfig(capacity: 0, perSourceQuota: -5, dedupMemory: 0, maxDeadLetters: -1)
        XCTAssertEqual(c.capacity, 1)
        XCTAssertEqual(c.perSourceQuota, 1)
        XCTAssertEqual(c.dedupMemory, 1)
        XCTAssertEqual(c.maxDeadLetters, 1)
        XCTAssertEqual(EventLogConfig(capacity: 2, perSourceQuota: 50).perSourceQuota, 2)
    }

    func testDeadLettersAndDedupMemoryAreBounded() async throws {
        let log = try EventLog(config: EventLogConfig(capacity: 1, perSourceQuota: 1, dedupMemory: 3, maxDeadLetters: 2),
                               storage: InMemoryEventLogStorage())
        for i in 0..<6 {
            _ = try await log.append(sig("s\(i)", i % 2 == 0 ? .notification : .calendar))
        }
        let snap = await log.snapshot()
        XCTAssertEqual(snap.deadLetters.count, 2)
        XCTAssertEqual(snap.deadLetters.map(\.event.signal.id), ["s3", "s4"], "oldest letters fall off first")
        XCTAssertEqual(snap.live.count, 1)
    }

    func testFileStorageRoundTripsAndRefusesCorruptFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("log.json")
        let storage = FileEventLogStorage(url: url)
        XCTAssertNil(try storage.load())

        let log = try EventLog(storage: storage)
        _ = try await log.append(sig("persisted"))
        let reopened = try EventLog(storage: FileEventLogStorage(url: url))
        let ids = await reopened.snapshot().live.map(\.signal.id)
        XCTAssertEqual(ids, ["persisted"])

        try Data("{not json".utf8).write(to: url)
        XCTAssertThrowsError(try EventLog(storage: FileEventLogStorage(url: url)))
    }
}
