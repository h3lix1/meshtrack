// ReplayReconstructor — the pure, deterministic replay engine for VCR playback
// (G9, §1). Given the observation corpus, a playhead, and the node positions, it
// reconstructs the EXACT set of PacketTraces "active" at that moment — the same
// overlay the live map (G1) draws — by feeding the windowed receptions up to the
// playhead through the same LivePacketTraceCollector / PacketTraceBuilder used
// live. It also derives the animation clock for the playhead so the trace heads
// sit where they would have, given the playback speed.
//
// Pure + total: (observations + playhead + speed + positions) → (traces + clock).
// No I/O, no Date(), no shared mutable state — so it is fully unit-testable and
// produces identical output for identical input.

import Domain

/// The reconstructed map state at a playhead: the active traces plus the
/// animation clock the map overlay should render at.
public struct ReplayFrame: Sendable, Equatable {
    public let traces: [PacketTrace]
    /// Seconds on the trace-animation clock (the value `NetworkMapView.clock`
    /// consumes). Advancing the playhead advances this; faster speeds advance it
    /// proportionally faster.
    public let clock: Double

    public init(traces: [PacketTrace], clock: Double) {
        self.traces = traces
        self.clock = clock
    }

    public static let empty = ReplayFrame(traces: [], clock: 0)
}

/// Reconstructs the active traces + clock at any playhead from the corpus.
public struct ReplayReconstructor: Sendable {
    /// How many of the most-recent packets animate at once (the sliding window,
    /// mirroring `LivePacketTraceCollector`).
    public let windowSize: Int
    /// Seconds between successive packets' animation starts (matches the live
    /// collector's `stagger`).
    public let stagger: Double

    public init(windowSize: Int = 12, stagger: Double = 0.4) {
        self.windowSize = max(1, windowSize)
        self.stagger = stagger
    }

    /// Reconstruct the frame active at `playhead`, given the (unordered) corpus
    /// and node positions, at the supplied playback `speed`.
    ///
    /// Determinism: observations are sorted by `(rxTime, packetID)`; only those
    /// at or before the playhead are folded in; the most-recent `windowSize`
    /// distinct packet ids survive (oldest evicted). The animation clock is the
    /// real seconds elapsed since the oldest surviving packet's arrival, scaled
    /// by `speed` — so at higher speed the heads have travelled further.
    public func frame(
        observations: [TimelineObservation],
        playhead: Instant,
        speed: PlaybackSpeed,
        positions: [Int64: GeoPoint]
    ) -> ReplayFrame {
        let upTo = observations
            .filter { $0.rxTime <= playhead }
            .sorted { lhs, rhs in
                lhs.rxTime == rhs.rxTime ? lhs.packetID < rhs.packetID : lhs.rxTime < rhs.rxTime
            }
        guard let oldest = windowedOldest(upTo) else { return .empty }

        var collector = LivePacketTraceCollector(maxPackets: windowSize)
        for observation in upTo {
            collector.ingest(decoded(observation))
        }
        let traces = collector.traces(positions: positions, stagger: stagger)
        let elapsed = playhead.secondsSince(oldest.rxTime)
        return ReplayFrame(traces: traces, clock: max(0, elapsed) * speed.rawValue)
    }

    /// The oldest observation that survives the sliding window at the playhead —
    /// the animation-clock origin. Nil when nothing is in window.
    private func windowedOldest(_ sorted: [TimelineObservation]) -> TimelineObservation? {
        var order: [UInt32] = []
        var firstByPacket: [UInt32: TimelineObservation] = [:]
        for observation in sorted {
            if firstByPacket[observation.packetID] == nil {
                order.append(observation.packetID)
                firstByPacket[observation.packetID] = observation
            }
        }
        guard !order.isEmpty else { return nil }
        let surviving = order.suffix(windowSize)
        return surviving.first.flatMap { firstByPacket[$0] }
    }

    /// Map a stored observation back to the DecodedPacket the live collector folds
    /// (same shape the ingest tap produces), so replay reuses the live path.
    private func decoded(_ observation: TimelineObservation) -> DecodedPacket {
        DecodedPacket(
            from: UInt32(truncatingIfNeeded: observation.fromNode),
            to: 0xFFFF_FFFF,
            packetID: observation.packetID,
            channel: 0,
            port: .other(0),
            payload: [],
            rxTime: observation.rxTime,
            hopStart: UInt8(clamping: observation.hopStart),
            hopLimit: UInt8(clamping: observation.hopLimit),
            relayNode: observation.relayNode == 0 ? nil : observation.relayNode,
            gatewayID: observation.gatewayNode.map { UInt32(truncatingIfNeeded: $0) }
        )
    }
}
