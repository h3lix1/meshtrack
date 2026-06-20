// Clock port + the Domain-native time type.
//
// This is the architectural keystone: Domain never reads the wall clock. All
// time enters through the `Clock` port, so every detector and evaluator is
// deterministic and unit-testable. `Date()` is BANNED in Domain (enforced by
// scripts/check-domain-purity.sh and a custom SwiftLint rule).
//
// Domain imports nothing but the standard library. `Synchronization` ships with
// the toolchain (not Foundation) and gives us a Sendable, lock-protected clock
// without any I/O.

import Synchronization

/// A wall-clock instant, expressed as integer nanoseconds since the Unix epoch.
///
/// Integer nanoseconds (not `Date`) keep Domain free of Foundation and make
/// instants exactly persistable and comparable.
public struct Instant: Hashable, Comparable, Sendable {
    public let nanosecondsSinceEpoch: Int64

    public init(nanosecondsSinceEpoch: Int64) {
        self.nanosecondsSinceEpoch = nanosecondsSinceEpoch
    }

    public static func < (lhs: Instant, rhs: Instant) -> Bool {
        lhs.nanosecondsSinceEpoch < rhs.nanosecondsSinceEpoch
    }
}

public extension Instant {
    /// The Unix epoch (1970-01-01T00:00:00Z).
    static let epoch = Instant(nanosecondsSinceEpoch: 0)

    /// A new instant `seconds` later (or earlier, if negative).
    func adding(seconds: Double) -> Instant {
        Instant(nanosecondsSinceEpoch: nanosecondsSinceEpoch + Self.nanos(fromSeconds: seconds))
    }

    /// Signed seconds elapsed from `other` to `self`.
    func secondsSince(_ other: Instant) -> Double {
        Double(nanosecondsSinceEpoch - other.nanosecondsSinceEpoch) / 1_000_000_000
    }

    internal static func nanos(fromSeconds seconds: Double) -> Int64 {
        Int64((seconds * 1_000_000_000).rounded())
    }
}

/// Port: the only source of "now" available to Domain.
///
/// Production wires `SystemClock` (composition root). Tests and the replay
/// pipeline wire `InjectedClock`, which advances deterministically.
public protocol Clock: Sendable {
    func now() -> Instant
}

/// A deterministic, manually-advanced clock.
///
/// Used by unit tests *and* in production by the replay pipeline, where time is
/// driven from each packet's `rx_time` rather than the host wall clock.
public final class InjectedClock: Clock {
    private let state: Mutex<Instant>

    public init(_ start: Instant = .epoch) {
        state = Mutex(start)
    }

    public func now() -> Instant {
        state.withLock { $0 }
    }

    /// Pin the clock to an exact instant.
    public func set(_ instant: Instant) {
        state.withLock { $0 = instant }
    }

    /// Advance the clock by `seconds` (negative moves it backward).
    public func advance(seconds: Double) {
        state.withLock { $0 = $0.adding(seconds: seconds) }
    }
}
