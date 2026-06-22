// PacketTraceBuilder — reconstructs packet journeys for the visualization from
// per-gateway receptions (SPEC §1). The previous hop is GUESSED from the
// relay-node hint (last byte of the relayer's node id, MeshPacket.relay_node):
// match nodes whose id ends in that byte and pick the one nearest the receiving
// gateway. Pure + tested.
//
// Receivers (item 8): the trace carries every node we have EVIDENCE received the packet,
// each tagged with the hop at which it heard it. That is:
//   - every distinct gateway that reported (uplinked) the packet id,
//   - the guessed relay(s),
//   - the addressed destination (`DecodedPacket.to`), as the last/furthest hop, when the
//     packet is unicast (not broadcast 0xffffffff/0, not self-addressed).
// Receivers WITH a known position become drawable `TraceReceiver`s; those WITHOUT one are
// NOT silently dropped — they become `UnpositionedReceiver`s for the textual legend list.
//
// HONESTY LIMITATION: this is not — and cannot be — every node that physically overheard
// the packet. The mesh only reports gateways that uplinked to MQTT plus the 1-byte relay
// hint; a node that merely overheard a packet without rebroadcasting (and isn't the
// addressed destination) is never reported, so it is unknowable. We do NOT fabricate such
// receivers. "All receivers" therefore means "every receiver we have evidence for".

import Domain

/// One gateway's reception of a packet.
public struct PacketReception: Sendable, Equatable {
    public let packetID: UInt32
    public let fromNode: Int64
    /// The packet's addressed recipient (`DecodedPacket.to`). `nil`/broadcast for
    /// flood traffic; when it is a real unicast node it is the last-hop recipient (item 8).
    public let toNode: Int64?
    public let gatewayNode: Int64?
    /// Last byte of the previous hop (MeshPacket.relay_node); 0 = unknown.
    public let relayNode: UInt8
    public let hopStart: Int
    public let hopLimit: Int
    public let rxTime: Instant

    public init(
        packetID: UInt32, fromNode: Int64, toNode: Int64? = nil, gatewayNode: Int64?,
        relayNode: UInt8, hopStart: Int, hopLimit: Int, rxTime: Instant
    ) {
        self.packetID = packetID
        self.fromNode = fromNode
        self.toNode = toNode
        self.gatewayNode = gatewayNode
        self.relayNode = relayNode
        self.hopStart = hopStart
        self.hopLimit = hopLimit
        self.rxTime = rxTime
    }

    public var hops: Int {
        max(0, hopStart - hopLimit)
    }

    /// Hops floored at 1 — a reception is at least one hop from the source.
    var cappedHops: Int {
        max(1, hops)
    }

    /// The Meshtastic broadcast address(es) — `to` set to one of these means the packet is
    /// flood traffic with no single addressed recipient, so there is no "destination"
    /// receiver to mark.
    static let broadcastAddresses: Set<Int64> = [0, 0xFFFF_FFFF]

    /// The addressed unicast destination, or nil for broadcast/self-addressed traffic.
    var destinationNode: Int64? {
        guard let toNode, !Self.broadcastAddresses.contains(toNode), toNode != fromNode else { return nil }
        return toNode
    }
}

public enum PacketTraceBuilder {
    public static func build(
        receptions: [PacketReception],
        positions: [Int64: GeoPoint],
        startedAt: Double = 0
    ) -> [PacketTrace] {
        Dictionary(grouping: receptions, by: \.packetID)
            .compactMap { trace(receptions: $0.value, positions: positions, startedAt: startedAt) }
            .sorted { $0.id < $1.id }
    }

    private static func trace(
        receptions: [PacketReception],
        positions: [Int64: GeoPoint],
        startedAt: Double
    ) -> PacketTrace? {
        guard let first = receptions.first, let sourcePosition = positions[first.fromNode] else { return nil }
        let source = first.fromNode
        var edges: [TraceEdge] = []
        var receivers = ReceiverSet()

        for reception in receptions {
            // Record EVERY distinct gateway that reported this packet id (item 8 §2) — even
            // one whose position is unknown, so it surfaces in the textual list rather than
            // being silently dropped. Edges still need a position, so legs draw only when we
            // can place both ends.
            recordGateway(reception, into: &receivers, positions: positions)
            guard let gatewayPosition = receivers.positionedGateway(reception, positions),
                  receivers.markEdgesBuilt(for: reception) else { continue }
            let leg = journey(
                reception, source: source, sourcePosition: sourcePosition,
                gatewayPosition: gatewayPosition, positions: positions
            )
            edges += leg.edges
            if let relay = leg.relay {
                // The relay heard the packet one hop before the gateway it fed.
                receivers.record(relay, hop: max(1, reception.cappedHops - 1), kind: .relay, positions)
            }
        }
        recordDestination(receptions, source: source, into: &receivers, positions: positions)
        guard !edges.isEmpty else { return nil }
        return PacketTrace(
            id: first.packetID, sourceNode: source, edges: edges,
            hops: receptions.map(\.hops).max() ?? 0, startedAt: startedAt,
            receivers: receivers.positioned(), unpositionedReceivers: receivers.unpositioned()
        )
    }

    /// Record a gateway reception's gateway as a receiver (positioned → drawn; without a
    /// known position → listed). Dedup keeps the lowest hop seen for the node.
    private static func recordGateway(
        _ reception: PacketReception,
        into receivers: inout ReceiverSet,
        positions: [Int64: GeoPoint]
    ) {
        guard let gateway = reception.gatewayNode else { return }
        receivers.record(gateway, hop: reception.cappedHops, kind: .gateway, positions)
    }

    /// Record the packet's addressed destination as its last-hop recipient (item 8 §1),
    /// tagged with the max hop count (it is the furthest hop). Skipped for broadcast/self
    /// traffic and when the destination is already the source. Positioned → drawn as a
    /// distinct "destination" marker; unpositioned → listed.
    private static func recordDestination(
        _ receptions: [PacketReception],
        source: Int64,
        into receivers: inout ReceiverSet,
        positions: [Int64: GeoPoint]
    ) {
        guard let destination = receptions.lazy.compactMap(\.destinationNode).first else { return }
        let maxHop = max(1, receptions.map(\.hops).max() ?? 1)
        receivers.record(destination, hop: maxHop, kind: .destination, positions, force: true)
    }

    /// Accumulates the receiver set for one packet: positioned (drawable) receivers deduped
    /// by node keeping the lowest hop, plus the unpositioned ones we can only list, plus the
    /// gateways we've already drawn legs for (so a re-reception doesn't double-draw).
    private struct ReceiverSet {
        private var positionedByID: [Int64: TraceReceiver] = [:]
        private var unpositionedByID: [Int64: UnpositionedReceiver] = [:]
        private var edgesBuilt: Set<Int64> = []

        /// The first time we see a positioned gateway, claim it for leg-building so the same
        /// gateway reported twice doesn't draw duplicate edges.
        mutating func markEdgesBuilt(for reception: PacketReception) -> Bool {
            guard let gateway = reception.gatewayNode else { return false }
            return edgesBuilt.insert(gateway).inserted
        }

        func positionedGateway(_ reception: PacketReception, _ positions: [Int64: GeoPoint]) -> GeoPoint? {
            reception.gatewayNode.flatMap { positions[$0] }
        }

        /// Insert/merge a receiver. With a known position it goes in the drawable set; without
        /// one it goes in the listed set. `force` lets the destination override a node already
        /// recorded at a lower hop (it is genuinely the furthest/last hop, item 8).
        mutating func record(
            _ nodeID: Int64, hop: Int, kind: TraceReceiver.Kind,
            _ positions: [Int64: GeoPoint], force: Bool = false
        ) {
            if let position = positions[nodeID] {
                if let existing = positionedByID[nodeID], !force, existing.hop <= hop { return }
                positionedByID[nodeID] = TraceReceiver(
                    nodeID: nodeID, position: position, hop: hop, kind: kind
                )
            } else {
                if let existing = unpositionedByID[nodeID], !force, existing.hop <= hop { return }
                unpositionedByID[nodeID] = UnpositionedReceiver(nodeID: nodeID, hop: hop, kind: kind)
            }
        }

        func positioned() -> [TraceReceiver] {
            positionedByID.values.sorted { $0.nodeID < $1.nodeID }
        }

        func unpositioned() -> [UnpositionedReceiver] {
            unpositionedByID.values.sorted { $0.nodeID < $1.nodeID }
        }
    }

    /// One leg of the journey plus the relay node it routed through (nil when direct).
    private struct Leg {
        let edges: [TraceEdge]
        let relay: Int64?
    }

    private static func journey(
        _ reception: PacketReception, source: Int64, sourcePosition start: GeoPoint,
        gatewayPosition gateway: GeoPoint, positions: [Int64: GeoPoint]
    ) -> Leg {
        let gatewayHop = max(1, reception.hops)
        var excluding: Set<Int64> = [source]
        if let gatewayNode = reception.gatewayNode { excluding.insert(gatewayNode) }
        let relay = reception.relayNode == 0 ? nil
            : guessRelay(
                relayByte: reception.relayNode, excluding: excluding, positions: positions, near: gateway
            )
        guard let relay, let relayPosition = positions[relay] else {
            return Leg(
                edges: [TraceEdge(from: start, to: gateway, kind: .observed, hopIndex: gatewayHop)],
                relay: nil
            )
        }
        let relayHop = max(1, gatewayHop - 1)
        return Leg(
            edges: [
                TraceEdge(from: start, to: relayPosition, kind: .guessed, hopIndex: relayHop),
                TraceEdge(from: relayPosition, to: gateway, kind: .observed, hopIndex: gatewayHop)
            ],
            relay: relay
        )
    }

    /// Guess the relayer: a node whose id ends in `relayByte`, nearest to `near`.
    static func guessRelay(
        relayByte: UInt8, excluding: Set<Int64>, positions: [Int64: GeoPoint], near: GeoPoint
    ) -> Int64? {
        positions.keys
            .filter { UInt8(truncatingIfNeeded: $0) == relayByte && !excluding.contains($0) }
            .min { distance($0, to: near, positions) < distance($1, to: near, positions) }
    }

    private static func distance(
        _ node: Int64,
        to reference: GeoPoint,
        _ positions: [Int64: GeoPoint]
    ) -> Double {
        guard let point = positions[node] else { return .infinity }
        return Haversine.distanceMeters(from: point, to: reference)
    }
}
