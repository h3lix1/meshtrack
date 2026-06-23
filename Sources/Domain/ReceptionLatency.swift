// Reception→publish latency (SPEC §2.11).
//
// For every observation we record both the mesh `rx_time` and our `ingest_time`
// (Clock wall-clock at frame receipt). The gateway's receive→MQTT-publish latency
// is `ingest_time − rx_time`. This is descriptive telemetry only — never an alert
// input (clock skew between nodes makes it unreliable for thresholds). Pure so the
// inspector, map tooltips, and analytics share one computation.

/// The receive→publish latency for one reception.
public struct ReceptionLatency: Hashable, Sendable {
    /// Signed nanoseconds: `ingest_time − rx_time`. Negative means the node's
    /// claimed `rx_time` is ahead of our clock (clock skew).
    public let nanoseconds: Int64

    public init(nanoseconds: Int64) {
        self.nanoseconds = nanoseconds
    }

    /// Signed seconds elapsed from the mesh `rx_time` to our `ingest_time`.
    public var seconds: Double {
        Double(nanoseconds) / 1_000_000_000
    }

    /// Latency between the moment the mesh stamped the packet and the moment we
    /// ingested the frame.
    public init(rxTime: Instant, ingestTime: Instant) {
        nanoseconds = ingestTime.nanosecondsSinceEpoch - rxTime.nanosecondsSinceEpoch
    }
}

public extension ReceptionLatency {
    /// The latency for an observation, or `nil` when `ingestTime` is unknown
    /// (pre-v3 rows have no ingest time — latency is simply not available).
    static func between(rxTime: Instant, ingestTime: Instant?) -> ReceptionLatency? {
        guard let ingestTime else { return nil }
        return ReceptionLatency(rxTime: rxTime, ingestTime: ingestTime)
    }
}

// MARK: - Plausibility

/// A node's `rx_time` is whole seconds from its *own* RTC. A node whose clock is
/// skewed (commonly weeks behind, occasionally ahead) yields a `rxTime` far from
/// our ingest clock, so `ingest_time − rx_time` is astronomical (~4e9 ms) or
/// negative. Real gateway receive→MQTT-publish latency is sub-minute, so we treat
/// a generous ±2-minute window as the plausible band: wide enough to keep genuine
/// small skews and processing/queue delay visible, tight enough to reject the
/// stale-RTC garbage that would otherwise poison the histogram and the map overlay.
public extension ReceptionLatency {
    /// The widest receive→publish latency we treat as real. Anything beyond this
    /// (in either direction) is almost certainly node clock skew, not transport
    /// latency. ±120 s — gateway publish is realistically well under a minute.
    static let plausibleBoundSeconds: Double = 120

    private static var plausibleBoundNanos: Int64 {
        Int64(plausibleBoundSeconds) * 1_000_000_000
    }

    /// Whether this latency is small enough to be a real transport latency rather
    /// than a symptom of the node's skewed RTC. Symmetric around zero so a node a
    /// hair ahead of us still reads as a genuine (small, negative) skew.
    var isPlausible: Bool {
        abs(nanoseconds) <= Self.plausibleBoundNanos
    }

    /// Latency in milliseconds (rounded) *only when plausible*; `nil` when the
    /// reception's `rx_time` is implausible (out of the sane band — stale RTC).
    /// Callers render `nil` honestly ("clock skew" / "—") and exclude it from
    /// stats and the map's latency overlay.
    var plausibleMillis: Int? {
        guard isPlausible else { return nil }
        return Int((seconds * 1000).rounded())
    }
}
