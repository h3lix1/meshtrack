// PacketTraceRouting — route-leg reconstruction helpers for PacketTraceBuilder.
// Turns each packet report's relay/router byte into the immediate previous-hop edge.

import Domain

struct PacketReceiverAnchor: Equatable {
    let nodeID: Int64
    let position: GeoPoint
}

struct PacketRouteArrival: Hashable {
    let nodeID: Int64
    let hop: Int
}

struct PacketTraceRelay {
    let nodeID: Int64
    let hop: Int
    let heardFrom: PacketReceiverAnchor?
}

struct PacketTraceLeg {
    let edges: [TraceEdge]
    let relays: [PacketTraceRelay]
    let receiverAnchor: PacketReceiverAnchor?
    let arrivals: Set<PacketRouteArrival>
}

struct PacketTraceJourneyContext {
    let source: Int64
    let sourcePosition: GeoPoint
    let gatewayPosition: GeoPoint
    let positions: [Int64: GeoPoint]
    let relayGuessing: RelayGuessingPolicy
    let knownArrivals: Set<PacketRouteArrival>
    /// Nodes that never rebroadcast (CLIENT_MUTE role), so they can only ever be the
    /// first hop (source) or last hop (addressed destination) — never an intermediate
    /// relay. Excluded from relay-byte guess candidates.
    let nonRelayNodes: Set<Int64>

    init(
        source: Int64,
        sourcePosition: GeoPoint,
        gatewayPosition: GeoPoint,
        positions: [Int64: GeoPoint],
        relayGuessing: RelayGuessingPolicy,
        knownArrivals: Set<PacketRouteArrival>,
        nonRelayNodes: Set<Int64> = []
    ) {
        self.source = source
        self.sourcePosition = sourcePosition
        self.gatewayPosition = gatewayPosition
        self.positions = positions
        self.relayGuessing = relayGuessing
        self.knownArrivals = knownArrivals
        self.nonRelayNodes = nonRelayNodes
    }
}

extension PacketTraceBuilder {
    static func journey(_ reception: PacketReception, context: PacketTraceJourneyContext) -> PacketTraceLeg {
        let gatewayHop = max(1, reception.hops)
        let directArrival = reception.gatewayNode.map { PacketRouteArrival(nodeID: $0, hop: gatewayHop) }
        let sourceAnchor = PacketReceiverAnchor(nodeID: context.source, position: context.sourcePosition)
        let routed = routedRelays(for: reception, gatewayHop: gatewayHop, context: context)
        guard !routed.isEmpty else {
            // No relay hint to anchor this reception on. When we already know a node that
            // arrived earlier, chain onto it and draw the edge at its true hop, so hop N
            // starts where hop N-1 finished. Otherwise we can't decompose the path: rather
            // than draw a later-hop edge leaving the source (which reads as the source
            // re-sending the same packet), we draw a single FIRST-hop segment from the
            // source. The source therefore only ever originates hop-1 edges.
            if gatewayHop > 1, let chained = earlierArrival(beforeHop: gatewayHop, context: context) {
                return directLeg(
                    edgeHopIndex: gatewayHop,
                    origin: chained,
                    gatewayPosition: context.gatewayPosition,
                    directArrival: directArrival,
                    context: context
                )
            }
            return directLeg(
                edgeHopIndex: 1,
                origin: sourceAnchor,
                gatewayPosition: context.gatewayPosition,
                directArrival: directArrival,
                context: context
            )
        }
        return relayedLeg(routed, directArrival: directArrival, sourceAnchor: sourceAnchor, context: context)
    }

    /// The nearest node already known to have arrived before `gatewayHop`, used to chain a
    /// hint-less report onto the real previous hop instead of the source. Prefers the closest
    /// preceding hop, then proximity to the gateway. Excludes the source (it only transmits
    /// the first hop) and any node without a known position. `nil` when nothing earlier is
    /// known — the caller then anchors a single first-hop segment on the source instead.
    private static func earlierArrival(
        beforeHop gatewayHop: Int,
        context: PacketTraceJourneyContext
    ) -> PacketReceiverAnchor? {
        context.knownArrivals
            .filter { $0.hop >= 1 && $0.hop < gatewayHop && $0.nodeID != context.source }
            .compactMap { arrival -> (anchor: PacketReceiverAnchor, hop: Int)? in
                context.positions[arrival.nodeID].map {
                    (PacketReceiverAnchor(nodeID: arrival.nodeID, position: $0), arrival.hop)
                }
            }
            .min { lhs, rhs in
                if lhs.hop != rhs.hop { return lhs.hop > rhs.hop } // prefer the closest preceding hop
                let lhsDistance = Haversine.distanceMeters(from: lhs.anchor.position, to: context.gatewayPosition)
                let rhsDistance = Haversine.distanceMeters(from: rhs.anchor.position, to: context.gatewayPosition)
                if lhsDistance == rhsDistance { return lhs.anchor.nodeID < rhs.anchor.nodeID }
                return lhsDistance < rhsDistance
            }?.anchor
    }

    /// The nearest node we already have evidence arrived at `hop`, used to chain a later
    /// hop back onto the real previous hop instead of the source. Excludes the source and
    /// any node without a known position. `nil` when no such arrival is known — the caller
    /// then decides whether to fall back to the source or leave the node unanchored.
    static func nearestArrival(
        atHop hop: Int,
        near reference: GeoPoint,
        context: PacketTraceJourneyContext
    ) -> PacketReceiverAnchor? {
        guard hop >= 1 else { return nil }
        return context.knownArrivals
            .filter { $0.hop == hop && $0.nodeID != context.source }
            .compactMap { arrival in
                context.positions[arrival.nodeID]
                    .map { PacketReceiverAnchor(nodeID: arrival.nodeID, position: $0) }
            }
            .min { lhs, rhs in
                let lhsDistance = Haversine.distanceMeters(from: lhs.position, to: reference)
                let rhsDistance = Haversine.distanceMeters(from: rhs.position, to: reference)
                if lhsDistance == rhsDistance { return lhs.nodeID < rhs.nodeID }
                return lhsDistance < rhsDistance
            }
    }

    /// Guess the relayer: a node whose id ends in `relayByte`, nearest to `near`.
    static func guessRelay(
        relayByte: UInt8,
        excluding: Set<Int64>,
        positions: [Int64: GeoPoint],
        near: GeoPoint,
        policy: RelayGuessingPolicy = .nearestCandidate,
        nonRelayNodes: Set<Int64> = []
    ) -> Int64? {
        relayCandidates(
            relayByte: relayByte,
            excluding: excluding,
            positions: positions,
            near: near,
            policy: policy,
            nonRelayNodes: nonRelayNodes
        ).first
    }

    private static func relayCandidates(
        relayByte: UInt8,
        excluding: Set<Int64>,
        positions: [Int64: GeoPoint],
        near: GeoPoint,
        policy: RelayGuessingPolicy,
        nonRelayNodes: Set<Int64> = []
    ) -> [Int64] {
        // CLIENT_MUTE nodes never rebroadcast, so they can't be an intermediate relay —
        // drop them from the guess pool so they only ever appear as the source or the
        // addressed destination.
        let candidates = positions.keys.filter {
            UInt8(truncatingIfNeeded: $0) == relayByte
                && !excluding.contains($0)
                && !nonRelayNodes.contains($0)
        }.sorted {
            let lhsDistance = distance($0, to: near, positions)
            let rhsDistance = distance($1, to: near, positions)
            if lhsDistance == rhsDistance { return $0 < $1 }
            return lhsDistance < rhsDistance
        }
        switch policy {
        case .nearestCandidate:
            return Array(candidates.prefix(1))
        case .unambiguousOnly:
            return candidates.count == 1 ? candidates : []
        case .allCandidates:
            return candidates
        }
    }

    private struct RoutedRelay {
        let nodeID: Int64
        let position: GeoPoint
        let hop: Int
    }

    private static func routedRelays(
        for reception: PacketReception,
        gatewayHop: Int,
        context: PacketTraceJourneyContext
    ) -> [RoutedRelay] {
        guard gatewayHop > 1, reception.relayNode != 0 else { return [] }
        var excluding: Set<Int64> = [context.source]
        if let gatewayNode = reception.gatewayNode { excluding.insert(gatewayNode) }
        return relayCandidates(
            relayByte: reception.relayNode,
            excluding: excluding,
            positions: context.positions,
            near: context.gatewayPosition,
            policy: context.relayGuessing,
            nonRelayNodes: context.nonRelayNodes
        ).compactMap { relay in
            guard let relayPosition = context.positions[relay] else { return nil }
            return RoutedRelay(nodeID: relay, position: relayPosition, hop: gatewayHop - 1)
        }
    }

    /// One hint-less reception's edge. `edgeHopIndex` is the hop the EDGE is drawn at — the
    /// true gateway hop when chained onto an earlier node, or 1 for an undecomposable path
    /// anchored on the source (so the source never appears to originate a later hop). The
    /// gateway's true hop is still carried in `directArrival` for chaining and the badge.
    private static func directLeg(
        edgeHopIndex: Int,
        origin: PacketReceiverAnchor,
        gatewayPosition: GeoPoint,
        directArrival: PacketRouteArrival?,
        context: PacketTraceJourneyContext
    ) -> PacketTraceLeg {
        PacketTraceLeg(
            edges: [TraceEdge(
                from: origin.position,
                to: gatewayPosition,
                kind: .observed,
                hopIndex: edgeHopIndex
            )],
            relays: [],
            // The gateway heard the packet from this chained previous-hop node (or the
            // source when nothing earlier is known), so "Show all receivers" fans it out
            // from there rather than re-anchoring every receiver on the source.
            receiverAnchor: origin,
            arrivals: Set(directArrival.map { [$0] } ?? [])
        )
    }

    private static func relayedLeg(
        _ routed: [RoutedRelay],
        directArrival: PacketRouteArrival?,
        sourceAnchor: PacketReceiverAnchor,
        context: PacketTraceJourneyContext
    ) -> PacketTraceLeg {
        var arrivals = Set(routed.map { PacketRouteArrival(nodeID: $0.nodeID, hop: $0.hop) })
        if let directArrival { arrivals.insert(directArrival) }
        return PacketTraceLeg(
            edges: routed.flatMap { relayedEdges($0, sourceAnchor: sourceAnchor, context: context) },
            relays: routed.map {
                PacketTraceRelay(
                    nodeID: $0.nodeID,
                    hop: $0.hop,
                    heardFrom: relayOrigin(
                        forHop: $0.hop, near: $0.position, sourceAnchor: sourceAnchor, context: context
                    )
                )
            },
            receiverAnchor: receiverAnchor(for: routed),
            arrivals: arrivals
        )
    }

    /// Where a relay at `hop` heard the packet from: the source for the first hop,
    /// otherwise the nearest node we already know arrived one hop earlier. `nil` for a
    /// deeper relay with no known predecessor — we leave it unanchored rather than draw a
    /// misleading straight line all the way back to the source.
    private static func relayOrigin(
        forHop hop: Int,
        near reference: GeoPoint,
        sourceAnchor: PacketReceiverAnchor,
        context: PacketTraceJourneyContext
    ) -> PacketReceiverAnchor? {
        hop <= 1 ? sourceAnchor : nearestArrival(atHop: hop - 1, near: reference, context: context)
    }

    private static func receiverAnchor(for routed: [RoutedRelay]) -> PacketReceiverAnchor? {
        guard routed.count == 1, let relay = routed.first else { return nil }
        return PacketReceiverAnchor(nodeID: relay.nodeID, position: relay.position)
    }

    private static func relayedEdges(
        _ routed: RoutedRelay,
        sourceAnchor: PacketReceiverAnchor,
        context: PacketTraceJourneyContext
    ) -> [TraceEdge] {
        var edges: [TraceEdge] = []
        let arrival = PacketRouteArrival(nodeID: routed.nodeID, hop: routed.hop)
        // Draw the edge that delivered the packet TO this relay — from the source for a
        // first hop, otherwise from the nearest known previous-hop node — unless the relay
        // is already a known arrival (another reception already chained an edge into it).
        if !context.knownArrivals.contains(arrival),
           let origin = relayOrigin(
               forHop: routed.hop, near: routed.position, sourceAnchor: sourceAnchor, context: context
           ) {
            edges.append(TraceEdge(
                from: origin.position,
                to: routed.position,
                kind: .guessed,
                hopIndex: routed.hop
            ))
        }
        edges.append(TraceEdge(
            from: routed.position,
            to: context.gatewayPosition,
            kind: .observed,
            hopIndex: routed.hop + 1
        ))
        return edges
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

extension [PacketReception] {
    func sortedByRouteOrder() -> [PacketReception] {
        sorted { lhs, rhs in
            if lhs.cappedHops == rhs.cappedHops {
                if lhs.rxTime == rhs.rxTime {
                    return (lhs.gatewayNode ?? 0) < (rhs.gatewayNode ?? 0)
                }
                return lhs.rxTime < rhs.rxTime
            }
            return lhs.cappedHops < rhs.cappedHops
        }
    }
}
