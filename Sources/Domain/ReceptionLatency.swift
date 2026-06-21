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
