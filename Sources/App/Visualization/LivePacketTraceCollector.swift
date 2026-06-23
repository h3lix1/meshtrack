// LivePacketTraceCollector — folds the live decoded-packet stream into animated
// traces (SPEC §1). Each DecodedPacket becomes a per-gateway PacketReception;
// receptions are grouped by packet id over a sliding window (the most-recent N
// packets animate at once, oldest evicted). traces() reconstructs them via
// PacketTraceBuilder. Pure + tested; the view model feeds it from the ingest pipeline.
//
// Each packet records the animation-clock instant it first arrived (`arrivalClock`),
// stamped by the caller from the SAME reference clock the overlay's TimelineView ticks
// on (seconds since the reference date). `traces()` uses that instant as the trace's
// `startedAt`, so a newly-arrived packet animates from progress 0 forward (Task 2).
//
// The previous behaviour staggered `startedAt` by a tiny per-index offset (0, 0.4, …)
// while the overlay clock was ~7.9e8 s — `clock - startedAt` saturated every edge to
// 1, so hop lines appeared instantly fully-drawn. Anchoring to the real arrival clock
// fixes that. When no clock is supplied (replay/tests), it falls back to the legacy
// per-index stagger so existing deterministic paths are unchanged.

import Domain

public struct LivePacketTraceCollector: Sendable {
    private var receptionsByPacket: [UInt32: [PacketReception]] = [:]
    private var arrivalOrder: [UInt32] = []
    /// Animation-clock instant (seconds, reference-date based) each packet first
    /// arrived. nil for packets ingested without a clock (legacy/replay path).
    private var arrivalClockByPacket: [UInt32: Double] = [:]
    private let maxPackets: Int

    public init(maxPackets: Int = 12) {
        self.maxPackets = max(1, maxPackets)
    }

    public var packetCount: Int {
        arrivalOrder.count
    }

    /// Fold one decoded packet in as a gateway reception of its packet id.
    ///
    /// - Parameter arrivalClock: the current animation-clock value (seconds since the
    ///   reference date, the same clock `TimelineView(.animation)` ticks on). Stamped
    ///   once, when the packet id is first seen, and used as the trace's `startedAt` so
    ///   it animates from the moment it arrived. Omit (nil) for replay/tests, which
    ///   keeps the deterministic per-index stagger.
    public mutating func ingest(_ packet: DecodedPacket, arrivalClock: Double? = nil) {
        let reception = PacketReception(
            packetID: packet.packetID,
            fromNode: Int64(packet.from),
            // Thread the addressed recipient through so the builder can mark the last-hop
            // destination (item 8). Broadcast/self addresses are filtered downstream.
            toNode: Int64(packet.to),
            gatewayNode: packet.gatewayID.map { Int64($0) },
            relayNode: packet.relayNode ?? 0,
            hopStart: Int(packet.hopStart ?? 0),
            hopLimit: Int(packet.hopLimit ?? 0),
            rxTime: packet.rxTime
        )
        if receptionsByPacket[packet.packetID] == nil {
            arrivalOrder.append(packet.packetID)
            // Stamp arrival on first sight only — re-receptions of the same packet via
            // other gateways must not reset its animation.
            if let arrivalClock { arrivalClockByPacket[packet.packetID] = arrivalClock }
        }
        receptionsByPacket[packet.packetID, default: []].append(reception)
        while arrivalOrder.count > maxPackets {
            let evicted = arrivalOrder.removeFirst()
            receptionsByPacket[evicted] = nil
            arrivalClockByPacket[evicted] = nil
        }
    }

    /// Reconstruct traces for the windowed packets, oldest first.
    ///
    /// The window picks ONE `startedAt` regime so the overlay clock never mixes scales:
    /// if EVERY windowed packet carries a recorded `arrivalClock` (reference-date based,
    /// ~7.9e8 s), all packets use their real arrival clocks and draw from progress 0.
    /// If ANY packet lacks one (replay/tests, or a clockless packet beside clocked
    /// ones), the whole window falls back UNIFORMLY to the per-index `stagger`. Mixing
    /// the two — a ~0.4 stagger against a ~7.9e8 clock in the same frame — made hop
    /// lines saturate to fully-drawn instantly, which this avoids.
    public func traces(
        positions: [Int64: GeoPoint],
        stagger: Double = 0.4,
        relayGuessing: RelayGuessingPolicy = .nearestCandidate,
        nonRelayNodes: Set<Int64> = []
    ) -> [PacketTrace] {
        let allClocked = arrivalOrder.allSatisfy { arrivalClockByPacket[$0] != nil }
        return arrivalOrder.enumerated().flatMap { index, packetID in
            let startedAt = allClocked
                ? (arrivalClockByPacket[packetID] ?? Double(index) * stagger)
                : Double(index) * stagger
            return PacketTraceBuilder.build(
                receptions: receptionsByPacket[packetID] ?? [],
                positions: positions,
                startedAt: startedAt,
                relayGuessing: relayGuessing,
                nonRelayNodes: nonRelayNodes
            )
        }
    }
}
