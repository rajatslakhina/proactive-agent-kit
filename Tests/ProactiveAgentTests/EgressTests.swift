import XCTest
@testable import ProactiveAgent

final class EgressTests: XCTestCase {
    let dest = "cloud-model"

    func testNeverShareIsRedactedEvenWithEveryConsentGranted() {
        var ledger = ConsentLedger()
        for c in DataCategory.allCases { ledger.grant(c, to: dest, until: .infinity) }
        let signal = Signal(id: "x", source: .notification, receivedAt: 0, title: "Bank: your verification code is 482913",
                            fields: [SignalField("card", "4111 1111 1111 1111"), SignalField("app", "Bank")])
        guard case .allow(let ticket) = EgressPolicy().evaluate(signal, destination: dest, consent: ledger, now: 0) else {
            return XCTFail("the shareable remainder should still produce a ticket")
        }
        XCTAssertEqual(ticket.fields.map(\.redacted), [true, true, false])
        XCTAssertEqual(ticket.fields.first?.value, "[redacted:oneTimeCode]")
        XCTAssertFalse(ticket.fields.contains { $0.value.contains("482913") || $0.value.contains("4111") })

        let onlySecrets = Signal(id: "y", source: .notification, receivedAt: 0, title: "code 482913")
        XCTAssertEqual(EgressPolicy().evaluate(onlySecrets, destination: dest, consent: ledger, now: 0),
                       .localOnly(.nothingToShare, findings: []))
    }

    func testRegrantReplacesInsteadOfGrowing() {
        var ledger = ConsentLedger()
        ledger.grant(.contact, to: dest, until: 10)
        ledger.grant(.contact, to: dest, until: 20)
        XCTAssertEqual(ledger.grants.count, 1)
        XCTAssertTrue(ledger.isGranted(.contact, to: dest, now: 15))
    }

    /// The contact backstop: a broken classifier that labels an email "general" still cannot
    /// send it without consent.
    func testBrokenClassifierStillAsksBeforeSendingAnEmail() {
        let broken = EgressPolicy(classifier: PermissiveClassifier())
        XCTAssertEqual(broken.evaluate(Fixtures.lateMessage, destination: dest, consent: ConsentLedger(), now: 0),
                       .needsConsent([.contact]))
        var ledger = ConsentLedger()
        ledger.grant(.contact, to: dest, until: .infinity)
        guard case .allow = broken.evaluate(Fixtures.lateMessage, destination: dest, consent: ledger, now: 0) else {
            return XCTFail("consented contact is allowed")
        }
        let redacting = EgressPolicy(classifier: PermissiveClassifier(), unconsented: .redact)
        guard case .allow(let t) = redacting.evaluate(Fixtures.lateMessage, destination: dest, consent: ConsentLedger(), now: 0) else {
            return XCTFail("redact mode still sends the rest")
        }
        XCTAssertEqual(t.fields.first { $0.key == "sender" }?.value, "[redacted:contact]")
        // Mutation check: without the scanner the email goes straight out.
        let gutted = EgressPolicy(classifier: PermissiveClassifier(), unconsented: .ask, maxPayloadBytes: 4_096, scannerEnabled: false)
        guard case .allow(let leaked) = gutted.evaluate(Fixtures.lateMessage, destination: dest, consent: ConsentLedger(), now: 0) else {
            return XCTFail("expected the gutted policy to leak")
        }
        XCTAssertTrue(leaked.fields.contains { $0.value == "sam@example.com" })
    }

    func testNeverShareCannotBeConsentedTo() {
        var ledger = ConsentLedger()
        ledger.grant(.oneTimeCode, to: dest, until: .infinity)
        ledger.grant(.paymentCard, to: dest, until: .infinity)
        XCTAssertTrue(ledger.grants.isEmpty)
        XCTAssertFalse(ledger.isGranted(.oneTimeCode, to: dest, now: 0))
    }

    func testPersonalDataNeedsConsentPerDestinationAndExpires() {
        let signal = Fixtures.lateMessage
        let policy = EgressPolicy()
        XCTAssertEqual(policy.evaluate(signal, destination: dest, consent: ConsentLedger(), now: 0), .needsConsent([.contact]))

        var ledger = ConsentLedger()
        ledger.grant(.contact, to: "some-other-model", until: 100)
        XCTAssertEqual(policy.evaluate(signal, destination: dest, consent: ledger, now: 0), .needsConsent([.contact]),
                       "consent is per destination")

        ledger.grant(.contact, to: dest, until: 100)
        guard case .allow(let ticket) = policy.evaluate(signal, destination: dest, consent: ledger, now: 50) else {
            return XCTFail("consented contact should be allowed")
        }
        XCTAssertEqual(ticket.fields.first { $0.key == "sender" }?.value, "sam@example.com")
        XCTAssertEqual(policy.evaluate(signal, destination: dest, consent: ledger, now: 100), .needsConsent([.contact]),
                       "consent expires at expiresAt")
    }

    func testRedactModeSendsTheRestWithoutAsking() {
        let policy = EgressPolicy(unconsented: .redact)
        guard case .allow(let ticket) = policy.evaluate(Fixtures.lateMessage, destination: dest, consent: ConsentLedger(), now: 0) else {
            return XCTFail("redact mode should still produce a ticket")
        }
        let sender = ticket.fields.first { $0.key == "sender" }
        XCTAssertEqual(sender?.redacted, true)
        XCTAssertEqual(sender?.value, "[redacted:contact]")
    }

    /// The headline property: a classifier bug alone does not leak a one-time code.
    func testIndependentScannerCatchesWhatABrokenClassifierMisses() {
        let signal = Signal(id: "x", source: .notification, receivedAt: 0, title: "Please reply: code 482913",
                            fields: [SignalField("note", "card 4111-1111-1111-1111")])
        let decision = EgressPolicy(classifier: PermissiveClassifier()).evaluate(signal, destination: dest, consent: ConsentLedger(), now: 0)
        XCTAssertEqual(decision, .localOnly(.leakDetected, findings: [.oneTimeCode, .paymentCard]))
    }

    /// Mutation check for the test above: with the scanner removed as well, the same input
    /// *does* leak. If this ever stops leaking, the test above is no longer proving anything.
    func testWithoutTheScannerTheBrokenClassifierLeaks() {
        let signal = Signal(id: "x", source: .notification, receivedAt: 0, title: "Please reply: code 482913")
        let gutted = EgressPolicy(classifier: PermissiveClassifier(), unconsented: .ask, maxPayloadBytes: 4_096, scannerEnabled: false)
        guard case .allow(let ticket) = gutted.evaluate(signal, destination: dest, consent: ConsentLedger(), now: 0) else {
            return XCTFail("expected the gutted policy to leak")
        }
        XCTAssertTrue(ticket.fields.contains { $0.value.contains("482913") })
    }

    func testPayloadCapAndNothingToShare() {
        let big = Signal(id: "b", source: .backgroundTask, receivedAt: 0, title: String(repeating: "a", count: 5_000))
        XCTAssertEqual(EgressPolicy().evaluate(big, destination: dest, consent: ConsentLedger(), now: 0),
                       .localOnly(.payloadTooLarge, findings: []))
        let zeroCap = EgressPolicy(maxPayloadBytes: -10)
        XCTAssertEqual(zeroCap.maxPayloadBytes, 0)
    }

    func testDefaultClassifierLabels() {
        let c = DefaultEgressClassifier()
        XCTAssertEqual(c.categories(for: SignalField("title", "Lunch moved")), [.general])
        XCTAssertTrue(c.categories(for: SignalField("pin", "1234")).contains(.credential))
        XCTAssertFalse(c.categories(for: SignalField("shipping", "tomorrow")).contains(.credential), "'pin' must not match inside 'shipping'")
        XCTAssertTrue(c.categories(for: SignalField("title", "Your code: 1234")).contains(.oneTimeCode))
        XCTAssertTrue(c.categories(for: SignalField("note", "4111111111111111")).contains(.paymentCard))
        XCTAssertTrue(c.categories(for: SignalField("from", "a@b.co")).contains(.contact))
    }

    func testLeakScannerShapes() {
        let s = LeakScanner()
        XCTAssertEqual(s.scan("4111 1111 1111 1111"), [.paymentCard])
        XCTAssertTrue(s.scan("4111 1111 1111 1112").isEmpty, "fails Luhn: not a card")
        XCTAssertEqual(s.scan("use 482913 to sign in"), [.oneTimeCode])
        XCTAssertTrue(s.scan("meeting in 2026 at 1530").isEmpty, "4-digit runs are years/times, not OTPs")
        XCTAssertTrue(s.scan("123456789").isEmpty, "9 digits is neither an OTP nor a card")
        XCTAssertEqual(s.scan("your Password reset"), [.credentialMarker])
        XCTAssertTrue(s.scan("").isEmpty)
        XCTAssertEqual(s.scan("mail sam@example.com"), [.contactShape])
        XCTAssertEqual(s.scan("call +1 (415) 555-0134"), [.contactShape])
        XCTAssertTrue(s.scan("a@b and @x.y and z@.co").isEmpty, "not email shapes")
        XCTAssertFalse(LeakScanner.luhn([]))
        XCTAssertEqual(LeakScanner.digitRuns(in: "12a345678b9", lengths: 6...8), ["345678"])
    }

    func testTicketDigestCoversDestinationAndContent() {
        var ledger = ConsentLedger()
        ledger.grant(.contact, to: "a", until: .infinity)
        ledger.grant(.contact, to: "b", until: .infinity)
        guard case .allow(let ta) = EgressPolicy().evaluate(Fixtures.lateMessage, destination: "a", consent: ledger, now: 0),
              case .allow(let tb) = EgressPolicy().evaluate(Fixtures.lateMessage, destination: "b", consent: ledger, now: 0) else {
            return XCTFail("both should be allowed")
        }
        XCTAssertNotEqual(ta.digest, tb.digest)
    }
}
