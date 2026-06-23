// PacketTraceBuilder — reconstructs packet journeys for the visualization from
// per-gateway receptions (SPEC §1). The previous hop is GUESSED from the
// relay-node hint (last byte of the relayer's node id, MeshPacket.relay_node):
// match nodes whose id ends in that byte and pick the one nearest the receiving
// gateway by default. Callers can request unambiguous-only guessing to avoid drawing
// a misleading guessed next hop when several known nodes share that byte, or an
// all-candidates diagnostic mode that draws every colliding relay candidate. Pure + tested.
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

public enum RelayGuessingPolicy: String, Sendable, Equatable, Hashable, CaseIterable, Identifiable {
    /// Preserve the original behavior: when several known nodes share the relay byte,
    /// pick the candidate nearest the reporting gateway.
    case nearestCandidate
    /// Draw a guessed relay only when the relay byte identifies exactly one known node.
    /// Ambiguous bytes fall back to the direct source→gateway edge and do not add a
    /// guessed relay receiver.
    case unambiguousOnly
    /// Diagnostic mode: draw every known relay candidate whose node id ends with the
    /// reported relay byte, even when that makes the graph intentionally noisy.
    case allCandidates

    public var id: Self {
        self
    }
}

public enum PacketTraceBuilder {
    public static func build(
        receptions: [PacketReception],
        positions: [Int64: GeoPoint],
        startedAt: Double = 0,
        relayGuessing: RelayGuessingPolicy = .nearestCandidate,
        nonRelayNodes: Set<Int64> = []
    ) -> [PacketTrace] {
        Dictionary(grouping: receptions, by: \.packetID)
            .compactMap {
                trace(
                    receptions: $0.value,
                    positions: positions,
                    startedAt: startedAt,
                    relayGuessing: relayGuessing,
                    nonRelayNodes: nonRelayNodes
                )
            }
            .sorted { $0.id < $1.id }
    }

    private static func trace(
        receptions: [PacketReception],
        positions: [Int64: GeoPoint],
        startedAt: Double,
        relayGuessing: RelayGuessingPolicy,
        nonRelayNodes: Set<Int64>
    ) -> PacketTrace? {
        guard let first = receptions.first, let sourcePosition = positions[first.fromNode] else { return nil }
        let source = first.fromNode
        var edges: [TraceEdge] = []
        var receivers = PacketTraceReceiverSet()

        var knownArrivals: Set<PacketRouteArrival> = []
        for reception in receptions.sortedByRouteOrder() {
            guard let gatewayPosition = receivers.positionedGateway(reception, positions) else {
                recordGateway(reception, into: &receivers, positions: positions, heardFrom: nil)
                continue
            }
            guard receivers.markEdgesBuilt(for: reception) else { continue }
            let leg = journey(
                reception,
                context: PacketTraceJourneyContext(
                    source: source,
                    sourcePosition: sourcePosition,
                    gatewayPosition: gatewayPosition,
                    positions: positions,
                    relayGuessing: relayGuessing,
                    knownArrivals: knownArrivals,
                    nonRelayNodes: nonRelayNodes
                )
            )
            edges += leg.edges
            knownArrivals.formUnion(leg.arrivals)
            // Record EVERY distinct gateway that reported this packet id (item 8 §2) — even
            // one whose position is unknown, so it surfaces in the textual list rather than
            // being silently dropped. The receiver keeps its resolved previous-hop/router
            // anchor so "Show all receivers" can fan out from the correct hop.
            recordGateway(
                reception,
                into: &receivers,
                positions: positions,
                heardFrom: leg.receiverAnchor
            )
            for relay in leg.relays {
                // The relay heard the packet one hop before the gateway it fed.
                receivers.record(
                    relay.nodeID,
                    hop: relay.hop,
                    kind: .relay,
                    positions,
                    heardFrom: relay.heardFrom
                )
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
        into receivers: inout PacketTraceReceiverSet,
        positions: [Int64: GeoPoint],
        heardFrom: PacketReceiverAnchor?
    ) {
        guard let gateway = reception.gatewayNode else { return }
        receivers.record(
            gateway,
            hop: reception.cappedHops,
            kind: .gateway,
            positions,
            heardFrom: heardFrom
        )
    }

    /// Record the packet's addressed destination as its last-hop recipient (item 8 §1),
    /// tagged with the max hop count (it is the furthest hop). Skipped for broadcast/self
    /// traffic and when the destination is already the source. Positioned → drawn as a
    /// distinct "destination" marker; unpositioned → listed.
    private static func recordDestination(
        _ receptions: [PacketReception],
        source: Int64,
        into receivers: inout PacketTraceReceiverSet,
        positions: [Int64: GeoPoint]
    ) {
        guard let destination = receptions.lazy.compactMap(\.destinationNode).first else { return }
        let maxHop = max(1, receptions.map(\.hops).max() ?? 1)
        receivers.record(destination, hop: maxHop, kind: .destination, positions, force: true)
    }
}
