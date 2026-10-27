/// What a piece of data *is*. Categories are mapped to egress classes by `DataCategory.dataClass`;
/// that mapping is fixed in code, not configurable at runtime, because "is a one-time code
/// shareable?" is a policy decision, not a tuning knob.
public enum DataCategory: String, Codable, Sendable, CaseIterable, Hashable, Comparable {
    case general
    case contact
    case location
    case calendarDetail
    case messageBody
    case credential
    case oneTimeCode
    case paymentCard
    case health

    public var dataClass: DataClass {
        switch self {
        case .general: return .shareable
        case .contact, .location, .calendarDetail, .messageBody: return .needsConsent
        case .credential, .oneTimeCode, .paymentCard, .health: return .neverShare
        }
    }

    public static func < (lhs: DataCategory, rhs: DataCategory) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The three tiers from Claude Duet's published safety design: some data is fine to send,
/// some needs the user's consent, and some never leaves the device under any consent.
public enum DataClass: Int, Codable, Sendable, Comparable, Hashable {
    case shareable = 0
    case needsConsent = 1
    case neverShare = 2

    public static func < (lhs: DataClass, rhs: DataClass) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Labels a field with every category it might contain. Over-labelling is safe (it only
/// costs a consent prompt or a redaction); under-labelling is the failure mode.
public protocol EgressClassifier: Sendable {
    func categories(for field: SignalField) -> Set<DataCategory>
}

/// Key-name and value-shape rules. A Foundation Models classifier can replace this behind the
/// same protocol; the independent `LeakScanner` stays in place either way.
public struct DefaultEgressClassifier: EgressClassifier {
    public init() {}

    public func categories(for field: SignalField) -> Set<DataCategory> {
        var result: Set<DataCategory> = []
        let key = field.key.lowercased()
        let value = field.value.lowercased()

        let keyRules: [(DataCategory, [String])] = [
            (.credential, ["password", "passcode", "secret", "token"]),
            (.oneTimeCode, ["otp", "verification", "2fa"]),
            (.paymentCard, ["card", "cvv", "iban"]),
            (.health, ["health", "diagnosis", "medication", "heart"]),
            (.contact, ["email", "phone", "sender", "attendee", "recipient"]),
            (.location, ["location", "address", "coordinates"]),
            (.calendarDetail, ["event", "meeting", "calendar", "starts", "ends"]),
            (.messageBody, ["body", "message", "preview", "text"]),
        ]
        for (category, needles) in keyRules where needles.contains(where: { key.contains($0) }) {
            result.insert(category)
        }

        if key == "pin" { result.insert(.credential) }

        let valueRules: [(DataCategory, [String])] = [
            (.credential, ["password", "passcode"]),
            (.health, ["prescription", "diagnosis", "blood test"]),
        ]
        for (category, needles) in valueRules where needles.contains(where: { value.contains($0) }) {
            result.insert(category)
        }
        if value.contains("code") && !LeakScanner.digitRuns(in: value, lengths: 4...8).isEmpty {
            result.insert(.oneTimeCode)
        }
        if LeakScanner.containsCardNumber(value) { result.insert(.paymentCard) }
        if value.contains("@") && value.contains(".") { result.insert(.contact) }

        if result.isEmpty { result.insert(.general) }
        return result
    }
}

/// A second, independent check run on the *redacted* payload just before a ticket is minted.
/// It looks only at value shapes (never at keys or classifier output), so a classifier bug
/// cannot also blind it. Never-share shapes fail closed (the request stays on the device);
/// contact shapes fall back to a consent prompt. Consent-tier data with no recognisable shape
/// (a location name, a message body, calendar details) still depends on the classifier.
public struct LeakScanner: Sendable {
    public init() {}

    public enum Finding: String, Sendable, Hashable, Codable {
        case paymentCard
        case oneTimeCode
        case credentialMarker
        /// An email address or phone-number shape. Not a leak by itself: the policy turns it
        /// into a consent requirement unless contact sharing is already consented.
        case contactShape

        public var isNeverShare: Bool { self != .contactShape }
    }

    public func scan(_ text: String) -> Set<Finding> {
        var found: Set<Finding> = []
        if Self.containsCardNumber(text) { found.insert(.paymentCard) }
        // Standalone 6–8 digit runs are how OTPs look. 4-digit runs are excluded on purpose
        // (years, times); that gap is covered by the classifier's keyword rule instead.
        if !Self.digitRuns(in: text, lengths: 6...8).isEmpty { found.insert(.oneTimeCode) }
        let lower = text.lowercased()
        if ["password", "passcode", "cvv"].contains(where: { lower.contains($0) }) { found.insert(.credentialMarker) }
        if Self.containsEmail(text) || Self.containsPhoneNumber(text) { found.insert(.contactShape) }
        return found
    }

    /// `x@y.z` with non-empty parts around the `@` and a dot after it.
    static func containsEmail(_ text: String) -> Bool {
        for token in text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" || $0 == "<" || $0 == ">" }) {
            let parts = token.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, let local = parts.first, let domain = parts.last else { continue }
            if !local.isEmpty, domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") { return true }
        }
        return false
    }

    /// 10–12 digits in one run, allowing phone separators (space, dash, dot, parentheses, plus).
    /// Card-length runs (13+) are the card check's job. Over-matching only costs a consent prompt.
    static func containsPhoneNumber(_ text: String) -> Bool {
        var digits = 0
        for ch in text {
            if ch.isASCII, ch.isNumber {
                digits += 1 // bounded by text length
            } else if " -.()+".contains(ch) {
                continue
            } else {
                if (10...12).contains(digits) { return true }
                digits = 0
            }
        }
        return (10...12).contains(digits)
    }

    /// Maximal runs of ASCII digits whose length falls in `lengths`. Separators break a run.
    static func digitRuns(in text: String, lengths: ClosedRange<Int>) -> [String] {
        var runs: [String] = []
        var current = ""
        for ch in text {
            if ch.isASCII, ch.isNumber {
                current.append(ch)
            } else {
                if lengths.contains(current.count) { runs.append(current) }
                current = ""
            }
        }
        if lengths.contains(current.count) { runs.append(current) }
        return runs
    }

    /// 13–19 digits (spaces and dashes allowed between digits) passing the Luhn check.
    static func containsCardNumber(_ text: String) -> Bool {
        var digits: [Int] = []
        func flush() -> Bool {
            defer { digits.removeAll(keepingCapacity: true) }
            return (13...19).contains(digits.count) && luhn(digits)
        }
        for ch in text {
            if let d = ch.wholeNumberValue, ch.isASCII {
                digits.append(d)
            } else if ch == " " || ch == "-" {
                continue
            } else if flush() {
                return true
            }
        }
        return flush()
    }

    static func luhn(_ digits: [Int]) -> Bool {
        guard !digits.isEmpty else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            var d = digit
            if offset % 2 == 1 {
                d *= 2
                if d > 9 { d -= 9 }
            }
            sum += d // at most 19 digits × 9: cannot overflow
        }
        return sum % 10 == 0
    }
}

/// A user's consent for a category of data to reach one destination, until it expires.
public struct ConsentGrant: Codable, Sendable, Hashable {
    public let category: DataCategory
    public let destination: String
    public let expiresAt: Double
}

/// Value type: the loop owns one and mutations are explicit. Bounded by
/// categories × destinations because a re-grant replaces, never appends.
public struct ConsentLedger: Codable, Sendable, Hashable {
    public private(set) var grants: [ConsentGrant] = []

    public init() {}

    public mutating func grant(_ category: DataCategory, to destination: String, until expiresAt: Double) {
        // `neverShare` cannot be consented to; recording it would suggest otherwise.
        guard category.dataClass == .needsConsent else { return }
        grants.removeAll { $0.category == category && $0.destination == destination }
        grants.append(ConsentGrant(category: category, destination: destination, expiresAt: expiresAt))
    }

    public mutating func revoke(_ category: DataCategory, from destination: String) {
        grants.removeAll { $0.category == category && $0.destination == destination }
    }

    public func isGranted(_ category: DataCategory, to destination: String, now: Double) -> Bool {
        grants.contains { $0.category == category && $0.destination == destination && $0.expiresAt > now }
    }
}

/// A field after the policy has run: the original value, or a redaction marker.
public struct EgressField: Codable, Sendable, Hashable {
    public let key: String
    public let value: String
    public let redacted: Bool
}

/// Proof that a payload passed the egress policy. The initialiser is internal: code outside
/// this module (including the network layer) cannot mint one, so the only way to reach a
/// `CloudPlanner` is through `EgressPolicy.evaluate`. This is the boundary in the type system,
/// not in a code-review checklist.
public struct EgressTicket: Sendable, Hashable {
    public let destination: String
    public let fields: [EgressField]
    public let digest: StableDigest

    init(destination: String, fields: [EgressField]) {
        self.destination = destination
        self.fields = fields
        self.digest = StableDigest([destination] + fields.flatMap { [$0.key, $0.value] })
    }

    /// Approximate byte size of what leaves the device.
    public var byteCount: Int {
        fields.reduce(0) { Saturating.add($0, Saturating.add($1.key.utf8.count, $1.value.utf8.count)) }
    }
}

public enum LocalOnlyReason: String, Sendable, Hashable, Codable {
    case leakDetected
    case payloadTooLarge
    case nothingToShare
}

public enum EgressDecision: Sendable, Hashable {
    case allow(EgressTicket)
    case needsConsent(Set<DataCategory>)
    case localOnly(LocalOnlyReason, findings: Set<LeakScanner.Finding>)
}

public struct EgressPolicy: Sendable {
    public enum UnconsentedPersonalData: Sendable, Hashable {
        /// Ask the user before anything leaves (Duet's "needs consent to share").
        case ask
        /// Redact the unconsented fields and send the rest.
        case redact
    }

    public let classifier: any EgressClassifier
    public let scanner: LeakScanner
    public let unconsented: UnconsentedPersonalData
    public let maxPayloadBytes: Int
    /// Test seam only: lets a test prove the scanner is load-bearing. Internal on purpose.
    let scannerEnabled: Bool

    public init(classifier: any EgressClassifier = DefaultEgressClassifier(),
                unconsented: UnconsentedPersonalData = .ask,
                maxPayloadBytes: Int = 4_096) {
        self.init(classifier: classifier, unconsented: unconsented, maxPayloadBytes: maxPayloadBytes, scannerEnabled: true)
    }

    init(classifier: any EgressClassifier, unconsented: UnconsentedPersonalData, maxPayloadBytes: Int, scannerEnabled: Bool) {
        self.classifier = classifier
        self.scanner = LeakScanner()
        self.unconsented = unconsented
        self.maxPayloadBytes = Swift.max(0, maxPayloadBytes)
        self.scannerEnabled = scannerEnabled
    }

    public func evaluate(_ signal: Signal, destination: String, consent: ConsentLedger, now: Double) -> EgressDecision {
        var out: [EgressField] = []
        var missing: Set<DataCategory> = []

        for field in signal.allFields {
            let categories = classifier.categories(for: field)
            let worst = categories.map(\.dataClass).max() ?? .shareable
            switch worst {
            case .neverShare:
                out.append(Self.redact(field, categories))
            case .needsConsent:
                let personal = categories.filter { $0.dataClass == .needsConsent }
                let ungranted = personal.filter { !consent.isGranted($0, to: destination, now: now) }
                if ungranted.isEmpty {
                    out.append(EgressField(key: field.key, value: field.value, redacted: false))
                } else if unconsented == .redact {
                    out.append(Self.redact(field, categories))
                } else {
                    missing.formUnion(ungranted)
                }
            case .shareable:
                out.append(EgressField(key: field.key, value: field.value, redacted: false))
            }
        }

        if !missing.isEmpty { return .needsConsent(missing) }
        guard out.contains(where: { !$0.redacted }) else { return .localOnly(.nothingToShare, findings: []) }

        if scannerEnabled {
            let findings = out.filter { !$0.redacted }.reduce(into: Set<LeakScanner.Finding>()) {
                $0.formUnion(scanner.scan($1.value))
            }
            let neverShare = findings.filter(\.isNeverShare)
            if !neverShare.isEmpty { return .localOnly(.leakDetected, findings: neverShare) }
            // A contact shape the classifier didn't label: fall back to asking, unless contact
            // sharing to this destination is already consented.
            if findings.contains(.contactShape), !consent.isGranted(.contact, to: destination, now: now) {
                if unconsented == .redact {
                    out = out.map { field in
                        guard !field.redacted, scanner.scan(field.value).contains(.contactShape) else { return field }
                        return EgressField(key: field.key, value: "[redacted:contact]", redacted: true)
                    }
                    guard out.contains(where: { !$0.redacted }) else { return .localOnly(.nothingToShare, findings: []) }
                } else {
                    return .needsConsent([.contact])
                }
            }
        }

        let ticket = EgressTicket(destination: destination, fields: out)
        guard ticket.byteCount <= maxPayloadBytes else { return .localOnly(.payloadTooLarge, findings: []) }
        return .allow(ticket)
    }

    static func redact(_ field: SignalField, _ categories: Set<DataCategory>) -> EgressField {
        let label = categories.filter { $0.dataClass != .shareable }.sorted().map(\.rawValue).joined(separator: ",")
        return EgressField(key: field.key, value: "[redacted:\(label)]", redacted: true)
    }
}
