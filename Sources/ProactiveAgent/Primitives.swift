// Primitives shared by every stage: saturating arithmetic, a process-stable digest,
// and the injected clock. Nothing here allocates or traps.

/// Saturating integer arithmetic. Budgets, counters and backoff delays are computed with
/// these helpers so no public input can trap the process (`+`/`*` overflow traps in Swift).
public enum Saturating {
    @inlinable public static func add(_ a: Int, _ b: Int) -> Int {
        let (r, o) = a.addingReportingOverflow(b)
        return o ? (b > 0 ? Int.max : Int.min) : r
    }

    @inlinable public static func subtract(_ a: Int, _ b: Int) -> Int {
        let (r, o) = a.subtractingReportingOverflow(b)
        return o ? (b > 0 ? Int.min : Int.max) : r
    }

    @inlinable public static func multiply(_ a: Int, _ b: Int) -> Int {
        let (r, o) = a.multipliedReportingOverflow(by: b)
        guard o else { return r }
        return (a < 0) == (b < 0) ? Int.max : Int.min
    }

    /// Converts a `Double` to `Int` without trapping: NaN maps to `fallback`, values outside
    /// the `Int` range clamp to `Int.min`/`Int.max`. The bound is derived from `Int.max`
    /// so this is correct on 32-bit platforms as well.
    @inlinable public static func int(_ value: Double, fallback: Int = 0) -> Int {
        guard !value.isNaN else { return fallback }
        if value >= Double(Int.max) { return Int.max }
        if value <= Double(Int.min) { return Int.min }
        return Int(value)
    }
}

extension Double {
    /// Clamps into `range`; NaN maps to `range.lowerBound` (fail towards the conservative end).
    @inlinable func clamped(to range: ClosedRange<Double>) -> Double {
        guard !isNaN else { return range.lowerBound }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// FNV-1a 64-bit. Used for approval binding and idempotency keys because, unlike `Hasher`,
/// it is identical across processes and launches (an approval persisted across a relaunch
/// must still match the action it approved).
public struct StableDigest: Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: UInt64

    init(value: UInt64) { self.value = value }

    public init(_ parts: [String]) {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for part in parts {
            // Length-prefix every part so ["ab","c"] and ["a","bc"] never collide by construction.
            for byte in String(part.utf8.count).utf8 { h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
            h = (h ^ 0x3a) &* 0x0000_0100_0000_01b3
            for byte in part.utf8 { h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        }
        value = h
    }

    public var description: String {
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: Swift.max(0, 16 - hex.count)) + hex
    }
}

/// Seconds since an arbitrary epoch. Injected everywhere so tests and the demo are deterministic.
public typealias Clock = @Sendable () -> Double
