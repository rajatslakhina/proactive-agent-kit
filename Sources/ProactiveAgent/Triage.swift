/// What the agent thinks a signal calls for. Each intent maps to one tool module, which is
/// what makes progressive tool disclosure possible (see `ToolCatalog`).
public enum ProposedIntent: String, Codable, Sendable, CaseIterable, Hashable {
    case ignore
    case notifyUser
    case addReminder
    case draftReply
    case sendMessage
    case purchase

    /// Intents that need a plan from the cloud model. Everything else is planned on device.
    public var needsCloud: Bool {
        switch self {
        case .ignore, .notifyUser, .addReminder: return false
        case .draftReply, .sendMessage, .purchase: return true
        }
    }
}

public enum Urgency: Int, Codable, Sendable, Comparable, Hashable {
    case low = 0, normal = 1, high = 2, critical = 3
    public static func < (lhs: Urgency, rhs: Urgency) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct TriageResult: Sendable, Hashable {
    public let intent: ProposedIntent
    public let urgency: Urgency
    public let rationale: String
    /// Estimated on-device tokens this triage consumed; charged against the triage budget.
    public let tokens: Int
    /// True when the model could not run and this is the conservative stand-in.
    public let isFallback: Bool

    public init(intent: ProposedIntent, urgency: Urgency, rationale: String, tokens: Int = 0) {
        self.init(intent: intent, urgency: urgency, rationale: rationale, tokens: tokens, isFallback: false)
    }

    init(intent: ProposedIntent, urgency: Urgency, rationale: String, tokens: Int, isFallback: Bool) {
        self.intent = intent
        self.urgency = urgency
        self.rationale = rationale
        self.tokens = Swift.max(0, tokens)
        self.isFallback = isFallback
    }

    /// When the model is unavailable the agent may *tell* the user, never act for them.
    public static func fallback(_ why: String) -> TriageResult {
        TriageResult(intent: .notifyUser, urgency: .normal, rationale: "fallback: \(why)", tokens: 0, isFallback: true)
    }
}

public enum TriageModelError: Error, Sendable, Hashable {
    /// The model isn't ready (assets downloading, Apple Intelligence off, thermal throttling).
    case unavailable
}

/// The on-device triage model. In an app this is a Foundation Models session with a
/// `@Generable` result type; the package ships a deterministic stand-in so the loop's
/// behaviour is testable everywhere, including Linux CI.
public protocol TriageModel: Sendable {
    func triage(_ signal: Signal) async throws -> TriageResult
}

public struct HeuristicTriageModel: TriageModel {
    public init() {}

    public func triage(_ signal: Signal) async throws -> TriageResult {
        let text = signal.allFields.map(\.value).joined(separator: " ").lowercased()
        let tokens = Saturating.add(16, text.utf8.count / 4)
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }

        if has(["unsubscribe", "newsletter", "promo"]) {
            return TriageResult(intent: .ignore, urgency: .low, rationale: "marketing", tokens: tokens)
        }
        if has(["reorder", "running low", "buy again"]) {
            return TriageResult(intent: .purchase, urgency: .normal, rationale: "replenishment request", tokens: tokens)
        }
        if has(["running late", "can you reply", "let them know", "reply"]) {
            return TriageResult(intent: .sendMessage, urgency: .high, rationale: "someone is waiting on a reply", tokens: tokens)
        }
        if has(["conflict", "overlaps", "double-booked"]) {
            return TriageResult(intent: .draftReply, urgency: .high, rationale: "calendar conflict needs a response", tokens: tokens)
        }
        if has(["remind", "due", "deadline", "renew"]) {
            return TriageResult(intent: .addReminder, urgency: .normal, rationale: "time-bound task", tokens: tokens)
        }
        if has(["code", "verification", "security alert"]) {
            return TriageResult(intent: .notifyUser, urgency: .critical, rationale: "security-relevant", tokens: tokens)
        }
        return TriageResult(intent: .notifyUser, urgency: .low, rationale: "informational", tokens: tokens)
    }
}

/// A token budget that refills once per window. Each pipeline stage owns one, so the cloud
/// stage running dry cannot starve on-device triage, and vice versa.
public struct StageBudget: Sendable, Hashable {
    public let capacity: Int
    public let window: Double
    public private(set) var used: Int = 0
    public private(set) var windowStart: Double

    public init(capacity: Int, window: Double, now: Double) {
        self.capacity = Swift.max(0, capacity)
        // A zero, negative or NaN window would refill on every call (or never); clamp it.
        self.window = window.isFinite && window > 0 ? window : 60
        self.windowStart = now
    }

    public var remaining: Int { Swift.max(0, Saturating.subtract(capacity, used)) }

    /// Charges `cost` if it fits; returns false (and charges nothing) otherwise.
    public mutating func consume(_ cost: Int, now: Double) -> Bool {
        roll(now)
        let cost = Swift.max(0, cost)
        guard cost <= remaining else { return false }
        used = Saturating.add(used, cost)
        return true
    }

    /// Records an actual cost after the fact (e.g. tokens a model really used). May leave the
    /// budget exhausted; never traps.
    public mutating func charge(_ cost: Int, now: Double) {
        roll(now)
        used = Saturating.add(used, Swift.max(0, cost))
    }

    /// Returns `cost` to the budget, but only if the window it was charged in is still current.
    /// Used when a charged request never left the device (offline).
    public mutating func refund(_ cost: Int, chargedInWindowStartingAt start: Double) {
        guard start == windowStart else { return }
        used = Swift.max(0, Saturating.subtract(used, Swift.max(0, cost)))
    }

    /// Seconds until the budget refills (0 if there is room now).
    public func secondsUntilRefill(now: Double) -> Double {
        Swift.max(0, windowStart + window - now)
    }

    mutating func roll(_ now: Double) {
        guard now.isFinite, now >= windowStart + window else { return }
        let elapsedWindows = ((now - windowStart) / window).rounded(.down)
        windowStart += elapsedWindows * window
        used = 0
    }
}

/// Battery and power state, sampled by the host app (UIDevice / ProcessInfo) and passed in.
public struct EnergyState: Sendable, Hashable {
    public let batteryLevel: Double
    public let lowPowerMode: Bool

    public init(batteryLevel: Double, lowPowerMode: Bool) {
        // UIDevice reports -1 when monitoring is off; treat unknown as "full" only if not NaN.
        self.batteryLevel = batteryLevel < 0 ? 1 : batteryLevel.clamped(to: 0...1)
        self.lowPowerMode = lowPowerMode
    }

    public static let nominal = EnergyState(batteryLevel: 1, lowPowerMode: false)
}

/// Which stages may run in a given energy state. Radio use (cloud escalation) is the expensive
/// part, so it is cut first; on-device triage is cut only when the battery is nearly empty.
public struct EnergyPolicy: Sendable, Hashable {
    public let cloudMinimumBattery: Double
    public let triageMinimumBattery: Double

    public init(cloudMinimumBattery: Double = 0.2, triageMinimumBattery: Double = 0.05) {
        self.cloudMinimumBattery = cloudMinimumBattery.clamped(to: 0...1)
        self.triageMinimumBattery = triageMinimumBattery.clamped(to: 0...1)
    }

    public func allowsTriage(_ energy: EnergyState) -> Bool {
        energy.batteryLevel >= triageMinimumBattery
    }

    /// Critical work (a security alert) still escalates in Low Power Mode.
    public func allowsCloud(_ energy: EnergyState, urgency: Urgency) -> Bool {
        if urgency == .critical { return energy.batteryLevel >= triageMinimumBattery }
        return !energy.lowPowerMode && energy.batteryLevel >= cloudMinimumBattery
    }
}
