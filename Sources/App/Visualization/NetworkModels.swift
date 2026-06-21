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

    public init(
        id: Int64, name: String, position: GeoPoint,
        hopsFromGateway: Int, batteryPercent: Double? = nil, isGateway: Bool = false
    ) {
        self.id = id
        self.name = name
        self.position = position
        self.hopsFromGateway = hopsFromGateway
        self.batteryPercent = batteryPercent
        self.isGateway = isGateway
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

    public init(from: GeoPoint, to: GeoPoint, kind: Kind) {
        self.from = from
        self.to = to
        self.kind = kind
        lengthMeters = Haversine.distanceMeters(from: from, to: to)
    }
}

public struct PacketTrace: Identifiable, Sendable, Equatable {
    public let id: UInt32
    public let sourceNode: Int64
    public let edges: [TraceEdge]
    /// Hops taken (hop_start - hop_limit) as last observed.
    public let hops: Int
    /// When this trace started animating, seconds on the animation clock.
    public let startedAt: Double

    public init(id: UInt32, sourceNode: Int64, edges: [TraceEdge], hops: Int, startedAt: Double) {
        self.id = id
        self.sourceNode = sourceNode
        self.edges = edges
        self.hops = hops
        self.startedAt = startedAt
    }

    public var color: Color {
        PacketColor.color(for: id)
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
