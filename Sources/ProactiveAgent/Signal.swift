/// Where a signal entered the app. Sources are budgeted independently so one noisy source
/// (a notification storm) cannot starve the others (a calendar conflict).
public enum SignalSource: String, Codable, Sendable, CaseIterable, Hashable {
    case appIntent
    case notification
    case calendar
    case backgroundTask
}

/// One key/value pair carried by a signal. Sources do not label sensitivity: classification
/// is the egress policy's job, so a source cannot opt its own data out of the boundary.
public struct SignalField: Codable, Sendable, Hashable {
    public let key: String
    public let value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

/// An observation the agent may act on. `id` is the source's idempotency key: the same
/// notification delivered twice must produce one event, not two actions.
public struct Signal: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let source: SignalSource
    public let receivedAt: Double
    public let title: String
    public let fields: [SignalField]

    public init(id: String, source: SignalSource, receivedAt: Double, title: String, fields: [SignalField] = []) {
        self.id = id
        self.source = source
        self.receivedAt = receivedAt
        self.title = title
        self.fields = fields
    }

    /// The title is classified like any other field; it is the most common place a one-time
    /// code or an amount leaks ("Your code is 482913").
    public var allFields: [SignalField] { [SignalField("title", title)] + fields }
}
