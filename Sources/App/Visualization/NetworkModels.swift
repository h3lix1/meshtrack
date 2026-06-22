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
/// "show all receivers" overlay (item 6) can mark every node that heard the packet —
/// including non-repeaters / last hops that never rebroadcast — and annotate each with
/// its reception hop, not just the trace's final/max hop.
public struct TraceReceiver: Sendable, Equatable {
    public let nodeID: Int64
    public let position: GeoPoint
    /// The hop count at which this node received the packet (1 = direct from source).
    public let hop: Int
    /// True when this receiver is a gateway that reported the packet upstream.
    public let isGateway: Bool

    public init(nodeID: Int64, position: GeoPoint, hop: Int, isGateway: Bool) {
        self.nodeID = nodeID
        self.position = position
        self.hop = hop
        self.isGateway = isGateway
    }
}

public struct PacketTrace: Identifiable, Sendable, Equatable {
    public let id: UInt32
    public let sourceNode: Int64
    public let edges: [TraceEdge]
    /// Hops taken (hop_start - hop_limit) as last observed.
    public let hops: Int
    /// Every node that received this packet, each tagged with the hop at which it
    /// heard it (item 6). Includes the source's direct neighbours, intermediate
    /// relays, and the gateways. Empty for traces built without reception detail
    /// (older/sample paths) — the "show all receivers" overlay then has nothing to add.
    public let receivers: [TraceReceiver]
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
        receivers: [TraceReceiver] = [], preset: ChannelPreset? = nil
    ) {
        self.id = id
        self.sourceNode = sourceNode
        self.edges = edges
        self.hops = hops
        self.receivers = receivers
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
            hops: hops, startedAt: startedAt, receivers: receivers, preset: preset
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
