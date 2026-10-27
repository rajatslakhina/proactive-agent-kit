/// How much damage a tool can do. Consequential actions (sending as the user, spending money)
/// always require a human approval bound to the exact action.
public enum ActionRisk: Int, Codable, Sendable, Comparable, Hashable {
    case read = 0
    case reversible = 1
    case consequential = 2
    public static func < (lhs: ActionRisk, rhs: ActionRisk) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum ToolModule: String, Codable, Sendable, CaseIterable, Hashable {
    case notifications, reminders, messaging, commerce
}

public struct ToolDescriptor: Codable, Sendable, Hashable {
    public let name: String
    public let module: ToolModule
    public let risk: ActionRisk
    /// Tokens the tool's schema costs when it is placed in the model's context.
    public let schemaTokens: Int

    public init(name: String, module: ToolModule, risk: ActionRisk, schemaTokens: Int) {
        self.name = name
        self.module = module
        self.risk = risk
        self.schemaTokens = Swift.max(0, schemaTokens)
    }
}

/// One agent loop, many tool modules, loaded on demand. This is the "fold subagents back into
/// the main loop" design: instead of a messaging agent and a commerce agent coordinating,
/// one loop sees only the module the triaged intent needs.
public struct ToolCatalog: Sendable, Hashable {
    public let tools: [ToolDescriptor]

    public init(tools: [ToolDescriptor]) { self.tools = tools }

    public static func module(for intent: ProposedIntent) -> ToolModule? {
        switch intent {
        case .ignore: return nil
        case .notifyUser: return .notifications
        case .addReminder: return .reminders
        case .draftReply, .sendMessage: return .messaging
        case .purchase: return .commerce
        }
    }

    public func disclose(for intent: ProposedIntent) -> [ToolDescriptor] {
        guard let module = Self.module(for: intent) else { return [] }
        return tools.filter { $0.module == module }
    }

    public func tool(named name: String) -> ToolDescriptor? { tools.first { $0.name == name } }

    public var eagerSchemaTokens: Int { tools.reduce(0) { Saturating.add($0, $1.schemaTokens) } }

    public static let standard = ToolCatalog(tools: [
        ToolDescriptor(name: "notifications.post", module: .notifications, risk: .read, schemaTokens: 120),
        ToolDescriptor(name: "reminders.create", module: .reminders, risk: .reversible, schemaTokens: 180),
        ToolDescriptor(name: "messaging.draft", module: .messaging, risk: .reversible, schemaTokens: 260),
        ToolDescriptor(name: "messaging.send", module: .messaging, risk: .consequential, schemaTokens: 310),
        ToolDescriptor(name: "commerce.addToCart", module: .commerce, risk: .reversible, schemaTokens: 240),
        ToolDescriptor(name: "commerce.checkout", module: .commerce, risk: .consequential, schemaTokens: 420),
    ])
}

/// A concrete action. The digest covers the tool, the planner-written summary *and* every
/// argument (in sorted-key order), so anything a user can read on an approval card is bound.
/// Approval UIs should render `disclosure` (the raw arguments), never the summary alone: the
/// summary is free text from the cloud planner.
public struct PlannedAction: Codable, Sendable, Hashable {
    public let tool: String
    public let arguments: [String: String]
    public let summary: String

    public init(tool: String, arguments: [String: String], summary: String) {
        self.tool = tool
        self.arguments = arguments
        self.summary = summary
    }

    public var digest: StableDigest {
        StableDigest([tool, summary] + arguments.keys.sorted().flatMap { [$0, arguments[$0] ?? ""] })
    }

    /// One "key: value" line per argument, sorted by key: what the action will actually do.
    public var disclosure: [String] {
        arguments.keys.sorted().map { "\($0): \(arguments[$0] ?? "")" }
    }
}

/// The cloud planner. Its only input is an `EgressTicket`, which only `EgressPolicy` can mint,
/// so raw signals cannot reach it by construction.
public protocol CloudPlanner: Sendable {
    func plan(_ ticket: EgressTicket, intent: ProposedIntent, tools: [ToolDescriptor]) async throws -> PlannedAction?
}

public enum CloudPlannerError: Error, Sendable, Hashable {
    /// No connectivity. Does not count as an attempt.
    case offline
    /// The service answered with an error. Counts as an attempt.
    case failed(String)
}

/// Executes actions. `idempotencyKey` is stable across retries and relaunches, so the
/// downstream system can de-duplicate if the process dies between execute and journal.
public protocol ActionExecutor: Sendable {
    func execute(_ action: PlannedAction, idempotencyKey: StableDigest) async throws
}

/// A pending human decision, bound to the digest of one exact action.
public struct ApprovalRequest: Sendable, Hashable, Identifiable {
    public let id: UInt64
    public let eventSeq: UInt64
    public let action: PlannedAction
    public let digest: StableDigest
    public let expiresAt: Double
    public let egressed: EgressTicket?
}

/// Remembers which signals already produced their side effect. Keyed by signal id alone: each
/// event executes exactly one action, and a re-plan after a crash (a cloud model will rarely
/// reproduce the same wording or arguments) must still be recognised as the same side effect.
/// Bounded: the oldest keys fall off once `limit` is reached. The journal only has to cover
/// events that can be *re-processed* (in-flight or parked at a crash, i.e. still live in the
/// log), so `limit` must exceed the log's capacity; the default (512) is well above the default
/// capacity (64). Redeliveries of completed signals are stopped earlier, by the log's dedup window.
public struct ActionJournal: Codable, Sendable, Hashable {
    public let limit: Int
    private var order: [StableDigest] = []
    private var keys: Set<StableDigest> = []

    public init(limit: Int = 512) { self.limit = Swift.max(1, limit) }

    private enum CodingKeys: String, CodingKey { case limit, order }

    /// Decoding re-applies the same normalisation as `init(limit:)`: a persisted journal with a
    /// zero limit would otherwise evict every key on insert and silently stop de-duplicating.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        limit = Swift.max(1, try c.decode(Int.self, forKey: .limit))
        let decoded = try c.decode([StableDigest].self, forKey: .order)
        var seen: Set<StableDigest> = []
        order = Array(decoded.filter { seen.insert($0).inserted }.suffix(limit))
        keys = Set(order)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(limit, forKey: .limit)
        try c.encode(order, forKey: .order)
    }

    public static func key(signalID: String) -> StableDigest {
        StableDigest(["side-effect", signalID])
    }

    public func contains(_ key: StableDigest) -> Bool { keys.contains(key) }
    public var count: Int { keys.count }

    public mutating func record(_ key: StableDigest) {
        guard keys.insert(key).inserted else { return }
        order.append(key)
        if order.count > limit, let oldest = order.first {
            order.removeFirst()
            keys.remove(oldest)
        }
    }
}
