// Models for the live network visualization (SPEC §1 "ultimate visualization").
//
// A NetworkNode is a positioned node; a PacketTrace is one packet's observed
// journey across the mesh, reconstructed from per-gateway receptions and the
// relay-node hint (last byte of the previous hop). Each packet id gets a stable
// distinct colour; hop counts and per-node receive timing are carried for display.

import Domain
import SwiftUI

public struct NetworkNode: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let position: GeoPoint
    /// Hops from the nearest gateway (0 = gateway), for colouring/sizing.
    public let hopsFromGateway: Int
    public let batteryPercent: Double?
    public let isGateway: Bool
    /// The channel preset this node's live packets last arrived on, resolved from the
    /// `DecodedPacket.channel` hash (Task 4). nil until a packet is seen / unresolvable.
    public let preset: ChannelPreset?

    public init(
        id: Int64, name: String, position: GeoPoint,
        hopsFromGateway: Int, batteryPercent: Double? = nil, isGateway: Bool = false,
        preset: ChannelPreset? = nil
    ) {
        self.id = id
        self.name = name
        self.position = position
        self.hopsFromGateway = hopsFromGateway
        self.batteryPercent = batteryPercent
        self.isGateway = isGateway
        self.preset = preset
    }

    /// A copy with the channel preset replaced (Task 4) — fields are immutable, so the
    /// view model uses this to stamp a node's channel as live packets arrive.
    public func withPreset(_ preset: ChannelPreset?) -> NetworkNode {
        NetworkNode(
            id: id, name: name, position: position,
            hopsFromGateway: hopsFromGateway, batteryPercent: batteryPercent,
            isGateway: isGateway, preset: preset
        )
    }
}

/// One edge of a packet's journey: source → (guessed relay) → gateway.
public struct TraceEdge: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// An observed reception edge (relayer → gateway).
        case observed
        /// A guessed edge (from the relay-node last-byte hint), uncertain.
        case guessed
    }

    public let from: GeoPoint
    public let to: GeoPoint
    public let kind: Kind
    /// Geographic length in metres — used to normalise draw speed.
    public let lengthMeters: Double
    /// 1-based hop number of this edge along the packet's path (hop 1 is the first
    /// edge out of the source, hop 2 the next, …). All edges sharing a hop number
    /// form one ring of the expanding wavefront and animate together (item 2); the
    /// per-hop labels drawn when a packet is focused read this (item 3).
    public let hopIndex: Int

    public init(from: GeoPoint, to: GeoPoint, kind: Kind, hopIndex: Int = 1) {
        self.from = from
        self.to = to
        self.kind = kind
        self.hopIndex = hopIndex
        lengthMeters = Haversine.distanceMeters(from: from, to: to)
    }
}

/// A node that received a packet, with the hop at which it heard it. Surfaced so the
/// "show all receivers" overlay (item 6/8) can mark every node we have EVIDENCE heard the
/// packet — and annotate each with its reception hop, not just the trace's final/max hop.
///
/// Honesty note: this is NOT every node that physically overheard the packet. The mesh
/// only reports gateways that uplinked to MQTT plus the 1-byte relay hint; a node that
/// merely overheard a packet without rebroadcasting (and isn't the addressed destination)
/// is never reported, so we cannot know it. "Receiver" here = every node we have evidence
/// received it: reporting gateways, the guessed relay(s), and the addressed destination.
public struct TraceReceiver: Sendable, Equatable {
    /// What role the receiver played, for distinct styling (item 8).
    public enum Kind: Sendable, Equatable {
        /// A gateway that reported (uplinked) the packet to MQTT.
        case gateway
        /// A node guessed to have relayed the packet (from the relay-byte hint).
        case relay
        /// The packet's addressed last-hop recipient (`DecodedPacket.to`), when unicast.
        case destination
    }

    public let nodeID: Int64
    public let position: GeoPoint
    /// The hop count at which this node received the packet (1 = direct from source).
    public let hop: Int
    /// The receiver's role, driving its marker styling on the map.
    public let kind: Kind
    /// The resolved previous hop/router this receiver heard the packet from, when known.
    /// This lets "Show all receivers" fan listeners out from the correct router instead
    /// of guessing from only the receiver's hop number.
    public let heardFromNodeID: Int64?
    public let heardFromPosition: GeoPoint?

    /// True when this receiver is a gateway that reported the packet upstream. Retained
    /// for back-compat with existing renderer/tests; derived from `kind`.
    public var isGateway: Bool {
        kind == .gateway
    }

    /// True when this is the packet's addressed last-hop recipient (item 8).
    public var isDestination: Bool {
        kind == .destination
    }

    public init(
        nodeID: Int64,
        position: GeoPoint,
        hop: Int,
        kind: Kind,
        heardFromNodeID: Int64? = nil,
        heardFromPosition: GeoPoint? = nil
    ) {
        self.nodeID = nodeID
        self.position = position
        self.hop = hop
        self.kind = kind
        self.heardFromNodeID = heardFromNodeID
        self.heardFromPosition = heardFromPosition
    }

    /// Back-compat initialiser: `isGateway` maps to `.gateway`/`.relay`. Kept so existing
    /// call sites and tests compile unchanged (the task forbids breaking these).
    public init(nodeID: Int64, position: GeoPoint, hop: Int, isGateway: Bool) {
        self.init(nodeID: nodeID, position: position, hop: hop, kind: isGateway ? .gateway : .relay)
    }
}

/// A receiver we have evidence heard the packet but CANNOT place on the map (no known
/// position). Not silently dropped (item 8 §2) — surfaced as a compact textual "received
/// by (reported)" list in the focused-packet legend so "all receivers" stays complete.
public struct UnpositionedReceiver: Sendable, Equatable, Identifiable {
    public let nodeID: Int64
    /// The hop count at which this node received the packet (0 = unknown / direct).
    public let hop: Int
    public let kind: TraceReceiver.Kind

    public var id: Int64 {
        nodeID
    }

    public init(nodeID: Int64, hop: Int, kind: TraceReceiver.Kind) {
        self.nodeID = nodeID
        self.hop = hop
        self.kind = kind
    }
}

public struct PacketTrace: Identifiable, Sendable, Equatable {
    public let id: UInt32
    public let sourceNode: Int64
    public let edges: [TraceEdge]
    /// Hops taken (hop_start - hop_limit) as last observed.
    public let hops: Int
    /// Every node we have evidence received this packet AND can place on the map, each
    /// tagged with the hop at which it heard it (item 6/8). Includes intermediate relays,
    /// the gateways, and the addressed destination (item 8). Empty for traces built without
    /// reception detail (older/sample paths) — "show all receivers" then has nothing to add.
    public let receivers: [TraceReceiver]
    /// Receivers we have evidence heard the packet but have NO known position for, so they
    /// can't be drawn (item 8 §2). Surfaced as a textual list in the focused-packet legend
    /// rather than silently dropped, so "all receivers" is genuinely complete.
    public let unpositionedReceivers: [UnpositionedReceiver]
    /// When this trace started animating, seconds on the animation clock.
    public let startedAt: Double
    /// The channel preset this packet ACTUALLY arrived on, captured immutably at ingest
    /// time (Finding 20). Filtering by channel reads this — not the source node's *live*
    /// preset, which is overwritten when that node later transmits on another channel —
    /// so a historical trace stays under its original channel filter forever. nil when
    /// the channel is unknown/unresolved (older/replay paths that don't stamp it).
    public let preset: ChannelPreset?

    public init(
        id: UInt32, sourceNode: Int64, edges: [TraceEdge], hops: Int, startedAt: Double,
        receivers: [TraceReceiver] = [], unpositionedReceivers: [UnpositionedReceiver] = [],
        preset: ChannelPreset? = nil
    ) {
        self.id = id
        self.sourceNode = sourceNode
        self.edges = edges
        self.hops = hops
        self.receivers = receivers
        self.unpositionedReceivers = unpositionedReceivers
        self.startedAt = startedAt
        self.preset = preset
    }

    public var color: Color {
        PacketColor.color(for: id)
    }

    /// The highest hop number across this trace's edges — the wavefront has fully
    /// expanded once the clock reaches this ring (item 2).
    public var maxHopIndex: Int {
        edges.map(\.hopIndex).max() ?? 0
    }

    /// A copy with the channel preset replaced — fields are immutable, so the view model
    /// uses this to stamp a freshly-built trace with the channel it arrived on (Finding 20).
    public func withPreset(_ preset: ChannelPreset?) -> PacketTrace {
        PacketTrace(
            id: id, sourceNode: sourceNode, edges: edges,
            hops: hops, startedAt: startedAt, receivers: receivers,
            unpositionedReceivers: unpositionedReceivers, preset: preset
        )
    }
}

/// Deterministic, well-distributed colour per packet id (Knuth multiplicative hash
/// → hue), so each packet id reads as a distinct colour.
public enum PacketColor {
    public static func color(for packetID: UInt32) -> Color {
        let hashed = packetID &* 2_654_435_761
        let hue = Double(hashed % 1000) / 1000.0
        return Color(hue: hue, saturation: 0.85, brightness: 1.0)
    }
}
