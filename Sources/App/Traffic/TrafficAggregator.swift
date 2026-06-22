// TrafficAggregator — the pure, Sendable engine both analytics screens fold the
// decoded-packet stream into. It is deliberately I/O-free and value-typed so it can
// run off the main actor, be unit-tested deterministically, and be snapshotted into
// the persistence layer (`Store+TrafficStats`) without dragging SwiftUI along.
//
// COUNTING POLICY (documented once, here, for both screens):
//   The mesh floods DUPLICATE receptions of one logical packet — the same
//   `(from, packetID)` arrives via many gateways/relays. We track BOTH:
//     • `receptions`     — every fold() call (raw flood volume / airtime pressure).
//     • `distinctPackets`— unique `(from, packetID)` identities (logical traffic).
//   The port screen sorts by RECEPTIONS (that is the actual channel-occupancy a
//   port is responsible for), while reporting distinct packets too. The offenders
//   screen ranks by a node's EMITTED distinct packets (what it originated) plus the
//   reception spread (how far its traffic flooded), so a single chatty node is not
//   flattered or punished purely by how many gateways happened to hear it.

import Domain

/// Per-port running counters folded from the live stream.
public struct PortCounters: Sendable, Equatable {
    /// Every reception on this port (duplicate floods included).
    public var receptions: Int = 0
    /// Distinct `(from, packetID)` identities seen on this port.
    public var distinctPackets: Int = 0
    /// Distinct source node numbers that emitted on this port.
    public var sourceNodes: Set<UInt32> = []
    /// Distinct receiving locations (gateway ids; falls back to relay byte).
    public var gateways: Set<UInt32> = []
    /// The largest hop count (`hopStart - hopLimit`) seen on this port.
    public var maxHops: Int = 0
}

/// Per-node running counters folded from the live stream.
public struct NodeCounters: Sendable, Equatable {
    /// Distinct logical packets this node ORIGINATED (as `from`).
    public var emitted: Int = 0
    /// Every reception attributed to this node (flood volume it generated).
    public var receptions: Int = 0
    /// Distinct receiving locations/gateways that have heard this node — its spread.
    public var gateways: Set<UInt32> = []
    /// Per-port reception tally, so the offenders screen can name a dominant port.
    public var portReceptions: [Int: Int] = [:]
    /// First and last reception instants — the chattiness-over-time window.
    public var firstSeen: Instant?
    public var lastSeen: Instant?
}

/// The pure aggregator. Fold packets in with `fold(_:)`; read snapshots back out.
/// A value type: copy it to hand a consistent snapshot to another actor.
public struct TrafficAggregator: Sendable, Equatable {
    public private(set) var ports: [Int: PortCounters] = [:]
    public private(set) var nodes: [UInt32: NodeCounters] = [:]
    /// Total receptions across all ports (the denominator for "% of traffic").
    public private(set) var totalReceptions: Int = 0
    /// Distinct `(from, packetID)` identities seen anywhere — distinct-packet total.
    public private(set) var totalDistinctPackets: Int = 0
    /// Per-channel reception tally (an extra: busiest channels).
    public private(set) var channelReceptions: [UInt32: Int] = [:]
    /// Hop-count histogram across the whole mesh (an extra): hops → reception count.
    public private(set) var hopHistogram: [Int: Int] = [:]

    /// The dedup ledger of identities already counted toward DISTINCT tallies.
    private var seenIdentities: Set<UInt64> = []

    public init() {}

    /// Fold one decoded packet into every counter. Receptions always increment;
    /// distinct tallies increment only the first time an identity is seen.
    public mutating func fold(_ packet: DecodedPacket) {
        let raw = packet.port.portNumRawValue
        let hops = Self.hops(packet)
        let location = Self.location(packet)
        let isNewIdentity = seenIdentities.insert(Self.identity(packet)).inserted

        foldTotals(packet, isNew: isNewIdentity, hops: hops)
        foldPort(raw, packet: packet, location: location, hops: hops, isNew: isNewIdentity)
        foldNode(packet, raw: raw, location: location, isNew: isNewIdentity)
    }

    private mutating func foldTotals(_ packet: DecodedPacket, isNew: Bool, hops: Int) {
        totalReceptions += 1
        if isNew { totalDistinctPackets += 1 }
        channelReceptions[packet.channel, default: 0] += 1
        hopHistogram[hops, default: 0] += 1
    }

    private mutating func foldPort(
        _ raw: Int,
        packet: DecodedPacket,
        location: UInt32?,
        hops: Int,
        isNew: Bool
    ) {
        var counters = ports[raw] ?? PortCounters()
        counters.receptions += 1
        if isNew { counters.distinctPackets += 1 }
        counters.sourceNodes.insert(packet.from)
        if let location { counters.gateways.insert(location) }
        counters.maxHops = max(counters.maxHops, hops)
        ports[raw] = counters
    }

    private mutating func foldNode(
        _ packet: DecodedPacket,
        raw: Int,
        location: UInt32?,
        isNew: Bool
    ) {
        var counters = nodes[packet.from] ?? NodeCounters()
        counters.receptions += 1
        if isNew { counters.emitted += 1 }
        if let location { counters.gateways.insert(location) }
        counters.portReceptions[raw, default: 0] += 1
        if counters.firstSeen == nil { counters.firstSeen = packet.rxTime }
        counters.lastSeen = packet.rxTime
        nodes[packet.from] = counters
    }

    // MARK: Derivations

    /// Hops travelled = `hopStart - hopLimit`, floored at 0; 0 when either is absent.
    static func hops(_ packet: DecodedPacket) -> Int {
        guard let start = packet.hopStart, let limit = packet.hopLimit else { return 0 }
        return max(0, Int(start) - Int(limit))
    }

    /// The receiving location key: the MQTT gateway id, else the last-hop relay byte
    /// (so RF-only receptions still spread across distinct relays), else nil.
    static func location(_ packet: DecodedPacket) -> UInt32? {
        if let gateway = packet.gatewayID { return gateway }
        if let relay = packet.relayNode { return UInt32(relay) }
        return nil
    }

    /// The dedup identity of a reception: `from` in the high 32 bits, `packetID` low.
    static func identity(_ packet: DecodedPacket) -> UInt64 {
        (UInt64(packet.from) << 32) | UInt64(packet.packetID)
    }
}
