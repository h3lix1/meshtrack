// Sliding-window dedup (SPEC §2.4).
//
// The same MeshPacket may arrive via the local node, MQTT, and several gateways.
// Telemetry and position must be counted ONCE. This gates that once-only
// extraction — observation *provenance* rows are still recorded per reception
// (append-only); only the derived telemetry/position is deduplicated.
//
// Pure: time is passed in (from the Clock / packet rx_time), never read here. The
// owning ingestion actor holds one instance and mutates it; no shared state.

/// The dedup identity of a packet: `(packet_id, from_num)` (SPEC §2.4).
public struct DedupKey: Hashable, Sendable {
    public let packetID: UInt32
    public let fromNode: UInt32

    public init(packetID: UInt32, fromNode: UInt32) {
        self.packetID = packetID
        self.fromNode = fromNode
    }
}

/// A sliding time-window over recently-seen packet identities.
public struct DedupWindow: Sendable {
    /// Window length in seconds (default 600 = 10 minutes, SPEC §2.4).
    public let windowSeconds: Double
    private var lastSeen: [DedupKey: Instant]

    public init(windowSeconds: Double = 600) {
        self.windowSeconds = windowSeconds
        lastSeen = [:]
    }

    /// Live keys currently tracked (after the most recent admit's eviction).
    public var trackedCount: Int {
        lastSeen.count
    }

    /// Offer a packet seen at `time`. Returns `true` if this is the first sighting
    /// within the window (process the once-only extraction), `false` if it is a
    /// duplicate (skip it). A repeat sighting slides the window forward.
    public mutating func admit(_ key: DedupKey, at time: Instant) -> Bool {
        evict(asOf: time)
        if let previous = lastSeen[key], time.secondsSince(previous) <= windowSeconds {
            lastSeen[key] = time // slide the window on a repeat
            return false
        }
        lastSeen[key] = time
        return true
    }

    /// Drop keys whose last sighting is older than the window relative to `time`.
    private mutating func evict(asOf time: Instant) {
        lastSeen = lastSeen.filter { _, seen in
            time.secondsSince(seen) <= windowSeconds
        }
    }
}
