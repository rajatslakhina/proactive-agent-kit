import XCTest
@testable import ProactiveAgent

final class PrimitiveTests: XCTestCase {
    func testSaturatingArithmeticNeverTraps() {
        XCTAssertEqual(Saturating.add(Int.max, 1), Int.max)
        XCTAssertEqual(Saturating.add(Int.min, -1), Int.min)
        XCTAssertEqual(Saturating.subtract(Int.min, 1), Int.min)
        XCTAssertEqual(Saturating.subtract(Int.max, -1), Int.max)
        XCTAssertEqual(Saturating.multiply(Int.max, 2), Int.max)
        XCTAssertEqual(Saturating.multiply(Int.min, 2), Int.min)
        XCTAssertEqual(Saturating.multiply(Int.min, -1), Int.max)
        XCTAssertEqual(Saturating.add(2, 3), 5)
        XCTAssertEqual(Saturating.int(.nan, fallback: 7), 7)
        XCTAssertEqual(Saturating.int(.infinity), Int.max)
        XCTAssertEqual(Saturating.int(-.infinity), Int.min)
        XCTAssertEqual(Saturating.int(41.9), 41)
    }

    /// Known-answer vectors computed by an independent Python implementation of the same
    /// length-prefixed FNV-1a scheme. A per-process `Hasher` would fail this.
    func testStableDigestKnownAnswers() {
        XCTAssertEqual(StableDigest([]).description, "cbf29ce484222325")
        XCTAssertEqual(StableDigest(["ab", "c"]).description, "3258ba264f69a13e")
        XCTAssertEqual(StableDigest(["a", "bc"]).description, "55669b0488b5662e")
        let action = PlannedAction(tool: "messaging.send", arguments: ["to": "sam", "body": "hi"], summary: "Reply to Sam")
        XCTAssertEqual(action.digest.description, "311ffda3bb1d3d0d")
    }

    func testActionDigestBindsArgumentsAndSummaryButNotOrder() {
        let a = PlannedAction(tool: "messaging.send", arguments: ["to": "sam", "body": "hi"], summary: "x")
        let b = PlannedAction(tool: "messaging.send", arguments: ["body": "hi", "to": "sam"], summary: "x")
        let c = PlannedAction(tool: "messaging.send", arguments: ["to": "sam", "body": "hi!"], summary: "x")
        let d = PlannedAction(tool: "messaging.send", arguments: ["to": "sam", "body": "hi"], summary: "y")
        XCTAssertEqual(a.digest, b.digest)
        XCTAssertNotEqual(a.digest, c.digest)
        XCTAssertNotEqual(a.digest, d.digest, "the summary is shown to the user, so it is bound too")
        XCTAssertEqual(a.disclosure, ["body: hi", "to: sam"])
    }

    func testRefundOnlyAppliesToTheWindowItWasChargedIn() {
        var b = StageBudget(capacity: 100, window: 60, now: 0)
        XCTAssertTrue(b.consume(50, now: 0))
        let charged = b.windowStart
        XCTAssertTrue(b.consume(30, now: 61)) // new window: used = 30
        b.refund(50, chargedInWindowStartingAt: charged)
        XCTAssertEqual(b.remaining, 70, "a refund from an old window must not inflate the new one")
        b.refund(30, chargedInWindowStartingAt: b.windowStart)
        XCTAssertEqual(b.remaining, 100)
    }

    func testStageBudgetRefillsPerWindowAndHandlesBadInput() {
        var b = StageBudget(capacity: 100, window: 60, now: 0)
        XCTAssertTrue(b.consume(60, now: 1))
        XCTAssertFalse(b.consume(50, now: 2), "does not fit: nothing charged")
        XCTAssertEqual(b.remaining, 40)
        XCTAssertEqual(b.secondsUntilRefill(now: 2), 58)
        XCTAssertTrue(b.consume(50, now: 61), "new window")
        XCTAssertEqual(b.windowStart, 60)
        b.charge(Int.max, now: 62)
        XCTAssertEqual(b.remaining, 0)
        XCTAssertTrue(b.consume(-5, now: 62), "negative cost is clamped to zero")

        let weird = StageBudget(capacity: -1, window: .nan, now: 0)
        XCTAssertEqual(weird.capacity, 0)
        XCTAssertEqual(weird.window, 60)
    }

    func testEnergyPolicy() {
        let policy = EnergyPolicy()
        let lowPower = EnergyState(batteryLevel: 0.8, lowPowerMode: true)
        XCTAssertFalse(policy.allowsCloud(lowPower, urgency: .high))
        XCTAssertTrue(policy.allowsCloud(lowPower, urgency: .critical))
        XCTAssertFalse(policy.allowsCloud(EnergyState(batteryLevel: 0.1, lowPowerMode: false), urgency: .normal))
        XCTAssertFalse(policy.allowsTriage(EnergyState(batteryLevel: 0.01, lowPowerMode: false)))
        XCTAssertEqual(EnergyState(batteryLevel: -1, lowPowerMode: false).batteryLevel, 1, "-1 means monitoring off")
        XCTAssertEqual(EnergyState(batteryLevel: .nan, lowPowerMode: false).batteryLevel, 0, "unknown fails conservative")
        XCTAssertEqual(EnergyState(batteryLevel: 7, lowPowerMode: false).batteryLevel, 1)
    }

    func testJournalIsBounded() {
        var j = ActionJournal(limit: 2)
        let keys = (0..<3).map { StableDigest(["k\($0)"]) }
        keys.forEach { j.record($0) }
        j.record(keys[2])
        XCTAssertEqual(j.count, 2)
        XCTAssertFalse(j.contains(keys[0]))
        XCTAssertTrue(j.contains(keys[2]))
        XCTAssertEqual(ActionJournal(limit: 0).limit, 1)
    }

    func testBackoffIsExponentialAndCapped() {
        let c = AgentLoopConfig(baseBackoff: 2, maxBackoff: 30)
        XCTAssertEqual(c.backoff(afterAttempt: 1), 2)
        XCTAssertEqual(c.backoff(afterAttempt: 3), 8)
        XCTAssertEqual(c.backoff(afterAttempt: 10_000), 30)
        XCTAssertEqual(c.backoff(afterAttempt: Int.min), 2)
        XCTAssertEqual(AgentLoopConfig(maxAttempts: 0).maxAttempts, 1)
    }

    func testToolDisclosureIsPerModule() {
        let catalog = ToolCatalog.standard
        XCTAssertEqual(Set(catalog.disclose(for: .sendMessage).map(\.module)), [.messaging])
        XCTAssertTrue(catalog.disclose(for: .ignore).isEmpty)
        let disclosed = catalog.disclose(for: .purchase).reduce(0) { $0 + $1.schemaTokens }
        XCTAssertLessThan(disclosed, catalog.eagerSchemaTokens)
    }
}
