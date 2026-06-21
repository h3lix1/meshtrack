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

        for reception in receptions {
            guard let gateway = reception.gatewayNode, let gatewayPosition = positions[gateway],
                  seenGateways.insert(gateway).inserted else { continue }
            edges += journey(
                from: sourcePosition, to: gatewayPosition, relayNode: reception.relayNode,
                excluding: [source, gateway], positions: positions
            )
        }
        guard !edges.isEmpty else { return nil }
        return PacketTrace(
            id: first.packetID, sourceNode: source, edges: edges,
            hops: receptions.map(\.hops).max() ?? 0, startedAt: startedAt
        )
    }

    private static func journey(
        from start: GeoPoint, to gateway: GeoPoint, relayNode: UInt8,
        excluding: Set<Int64>, positions: [Int64: GeoPoint]
    ) -> [TraceEdge] {
        let relay = relayNode == 0 ? nil
            : guessRelay(relayByte: relayNode, excluding: excluding, positions: positions, near: gateway)
        guard let relay, let relayPosition = positions[relay] else {
            return [TraceEdge(from: start, to: gateway, kind: .observed)]
        }
        return [
            TraceEdge(from: start, to: relayPosition, kind: .guessed),
            TraceEdge(from: relayPosition, to: gateway, kind: .observed)
        ]
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
