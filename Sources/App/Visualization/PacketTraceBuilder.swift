// PacketTraceBuilder — reconstructs packet journeys for the visualization from
// per-gateway receptions (SPEC §1). The previous hop is GUESSED from the
// relay-node hint (last byte of the relayer's node id, MeshPacket.relay_node):
// match nodes whose id ends in that byte and pick the one nearest the receiving
// gateway. Nodes without a known position are ignored. Pure + tested.

import Domain

/// One gateway's reception of a packet.
public struct PacketReception: Sendable, Equatable {
    public let packetID: UInt32
    public let fromNode: Int64
    public let gatewayNode: Int64?
    /// Last byte of the previous hop (MeshPacket.relay_node); 0 = unknown.
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

    public var hops: Int {
        max(0, hopStart - hopLimit)
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
        var seenGateways: Set<Int64> = []
        // Every node that heard the packet, deduped, keeping the lowest reception hop.
        var receivers: [Int64: TraceReceiver] = [:]

        for reception in receptions {
            guard let gateway = reception.gatewayNode, let gatewayPosition = positions[gateway],
                  seenGateways.insert(gateway).inserted else { continue }
            let hops = max(1, reception.hops)
            let leg = journey(
                reception, source: source, sourcePosition: sourcePosition,
                gatewayPosition: gatewayPosition, positions: positions
            )
            edges += leg.edges
            record(&receivers, gateway: gateway, position: gatewayPosition, hop: hops)
            if let relay = leg.relay, let relayPosition = positions[relay] {
                // The relay heard the packet one hop before the gateway it fed.
                record(
                    &receivers,
                    gateway: relay,
                    position: relayPosition,
                    hop: max(1, hops - 1),
                    isGateway: false
                )
            }
        }
        guard !edges.isEmpty else { return nil }
        return PacketTrace(
            id: first.packetID, sourceNode: source, edges: edges,
            hops: receptions.map(\.hops).max() ?? 0, startedAt: startedAt,
            receivers: receivers.values.sorted { $0.nodeID < $1.nodeID }
        )
    }

    /// Insert/merge a receiver, keeping the *lowest* hop seen for that node (a node may
    /// appear via multiple gateways at different hop counts; the earliest reception wins).
    private static func record(
        _ receivers: inout [Int64: TraceReceiver],
        gateway nodeID: Int64, position: GeoPoint, hop: Int, isGateway: Bool = true
    ) {
        if let existing = receivers[nodeID], existing.hop <= hop { return }
        receivers[nodeID] = TraceReceiver(
            nodeID: nodeID, position: position, hop: hop, isGateway: isGateway
        )
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
