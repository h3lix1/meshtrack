// TimelineModel — pure value types for VCR / time-travel playback (G9, §1).
//
// These describe a scrubbable 24h window over the observation history: the window
// bounds, time buckets (for a density strip in the scrubber), the playhead, and
// the playback state (playing/paused, speed, live vs review). Everything here is
// pure and Sendable so the replay reconstruction (ReplayReconstructor) and the
// view model (TimelineViewModel) can be unit-tested deterministically.

import Domain

/// Playback speed multiplier. Constrained to the spec's discrete set {0.5,1,2,4}×.
public enum PlaybackSpeed: Double, Sendable, CaseIterable, Comparable {
    case half = 0.5
    case one = 1
    case two = 2
    case four = 4

    public static func < (lhs: PlaybackSpeed, rhs: PlaybackSpeed) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// A short label for the speed selector (e.g. "1×", "0.5×").
    public var label: String {
        self == .half ? "0.5\u{00d7}" : "\(Int(rawValue))\u{00d7}"
    }

    /// The next faster speed, clamped at 4×.
    public var faster: PlaybackSpeed {
        switch self {
        case .half: .one
        case .one: .two
        case .two: .four
        case .four: .four
        }
    }

    /// The next slower speed, clamped at 0.5×.
    public var slower: PlaybackSpeed {
        switch self {
        case .half: .half
        case .one: .half
        case .two: .one
        case .four: .two
        }
    }
}

/// Whether the timeline is tracking live traffic (playhead pinned to "now",
/// the live collector drives the map) or reviewing history (playhead scrubbed
/// into the past, the replay reconstructor drives the map).
public enum PlaybackMode: Sendable, Equatable {
    /// Following live ingest; the playhead sits at the window's end.
    case live
    /// Reviewing the past at the given playhead.
    case review
}

/// One reception drawn from the observation history, pre-projected into the form
/// the replay reconstructor needs. This is the pure replay corpus: the VM loads
/// it once from the store, then the reconstructor folds it up to any playhead
/// without further I/O.
public struct TimelineObservation: Sendable, Equatable {
    public let packetID: UInt32
    public let fromNode: Int64
    public let gatewayNode: Int64?
    public let relayNode: UInt8
    public let hopStart: Int
    public let hopLimit: Int
    public let rxTime: Instant

    public init(
        packetID: UInt32, fromNode: Int64, gatewayNode: Int64?,
        relayNode: UInt8, hopStart: Int, hopLimit: Int, rxTime: Instant
    ) {
        self.packetID = packetID
        self.fromNode = fromNode
        self.gatewayNode = gatewayNode
        self.relayNode = relayNode
        self.hopStart = hopStart
        self.hopLimit = hopLimit
        self.rxTime = rxTime
    }

    /// As the reception the trace builder consumes.
    public var reception: PacketReception {
        PacketReception(
            packetID: packetID, fromNode: fromNode, gatewayNode: gatewayNode,
            relayNode: relayNode, hopStart: hopStart, hopLimit: hopLimit, rxTime: rxTime
        )
    }
}

/// The bounded, bucketed time span the scrubber spans (last 24h by default).
public struct TimelineWindow: Sendable, Equatable {
    public let start: Instant
    public let end: Instant
    /// Per-bucket observation counts across `[start, end)`, oldest first — drives
    /// the density strip drawn behind the scrubber.
    public let buckets: [Int]

    public init(start: Instant, end: Instant, buckets: [Int]) {
        self.start = start
        self.end = end
        self.buckets = buckets
    }

    /// Total span in seconds (>= 0).
    public var durationSeconds: Double {
        max(0, end.secondsSince(start))
    }

    /// An empty window pinned at `end` (no history yet).
    public static func empty(end: Instant) -> TimelineWindow {
        TimelineWindow(start: end, end: end, buckets: [])
    }

    /// Fraction in [0,1] of where `playhead` sits across the window (0 = start,
    /// 1 = end). Clamped; returns 1 for a zero-width window.
    public func fraction(of playhead: Instant) -> Double {
        let span = durationSeconds
        guard span > 0 else { return 1 }
        return min(1, max(0, playhead.secondsSince(start) / span))
    }

    /// The instant at `fraction` (in [0,1]) across the window — the inverse of
    /// `fraction(of:)`, for mapping a scrubber drag back to a playhead.
    public func instant(atFraction fraction: Double) -> Instant {
        let clamped = min(1, max(0, fraction))
        return start.adding(seconds: durationSeconds * clamped)
    }
}

/// Builds a `TimelineWindow` (bounds + density buckets) from a corpus of
/// observations. Pure: given the observations + `now` + bucket count, the window
/// is deterministic.
public enum TimelineWindowBuilder {
    public static let dayInSeconds: Double = 24 * 60 * 60

    /// Window = `[now - span, now]`, bucketed into `bucketCount` even slots.
    public static func build(
        observations: [TimelineObservation],
        now: Instant,
        spanSeconds: Double = dayInSeconds,
        bucketCount: Int = 96
    ) -> TimelineWindow {
        let count = max(1, bucketCount)
        let span = max(0, spanSeconds)
        let start = now.adding(seconds: -span)
        guard span > 0 else { return .empty(end: now) }

        var buckets = [Int](repeating: 0, count: count)
        for observation in observations {
            let offset = observation.rxTime.secondsSince(start)
            guard offset >= 0, offset <= span else { continue }
            let index = min(count - 1, Int(offset / span * Double(count)))
            buckets[index] += 1
        }
        return TimelineWindow(start: start, end: now, buckets: buckets)
    }
}
