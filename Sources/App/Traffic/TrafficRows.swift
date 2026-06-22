// TrafficRows — the pure, presentation-ready rows the analytics screens render,
// derived from a `TrafficAggregator` snapshot. Keeping the derivation here (pure,
// Sendable, unit-tested) keeps the view models thin and the SwiftUI views dumb.

import Domain

/// One row of the Port-numbers screen: a port + its catalogue entry + its stats.
public struct PortStatRow: Identifiable, Sendable, Equatable {
    public var id: Int {
        descriptor.rawValue
    }

    public let descriptor: PortDescriptor
    public let receptions: Int
    public let distinctPackets: Int
    public let sourceNodeCount: Int
    public let gatewayCount: Int
    public let maxHops: Int
    /// Share of total RECEPTIONS this port is responsible for, in 0...1.
    public let trafficShare: Double

    public init(
        descriptor: PortDescriptor,
        receptions: Int,
        distinctPackets: Int,
        sourceNodeCount: Int,
        gatewayCount: Int,
        maxHops: Int,
        trafficShare: Double
    ) {
        self.descriptor = descriptor
        self.receptions = receptions
        self.distinctPackets = distinctPackets
        self.sourceNodeCount = sourceNodeCount
        self.gatewayCount = gatewayCount
        self.maxHops = maxHops
        self.trafficShare = trafficShare
    }

    /// Whole-percent string for the share, e.g. "37%".
    public var sharePercentLabel: String {
        "\(Int((trafficShare * 100).rounded()))%"
    }
}

/// One row of the Largest-offenders screen: a node ranked by traffic burden.
public struct OffenderRow: Identifiable, Sendable, Equatable {
    public var id: UInt32 {
        nodeNum
    }

    public let nodeNum: UInt32
    /// Distinct logical packets the node ORIGINATED.
    public let emitted: Int
    /// Every reception attributed to the node (its flood contribution).
    public let receptions: Int
    /// Distinct gateways/locations that have heard it — its spread across the mesh.
    public let spread: Int
    /// Packets-per-minute over the node's observed window (chattiness over time).
    public let packetsPerMinute: Double
    /// The node's dominant port (most receptions), if any.
    public let dominantPort: PortDescriptor?

    public init(
        nodeNum: UInt32,
        emitted: Int,
        receptions: Int,
        spread: Int,
        packetsPerMinute: Double,
        dominantPort: PortDescriptor?
    ) {
        self.nodeNum = nodeNum
        self.emitted = emitted
        self.receptions = receptions
        self.spread = spread
        self.packetsPerMinute = packetsPerMinute
        self.dominantPort = dominantPort
    }

    /// The `!aabbccdd` node id for display.
    public var hexID: String {
        NodeID.hex(nodeNum)
    }
}

/// One row of the busiest-channels extra: a channel hash + its reception count.
public struct ChannelTrafficRow: Identifiable, Sendable, Equatable {
    public var id: UInt32 {
        channel
    }

    public let channel: UInt32
    public let receptions: Int
    public let trafficShare: Double

    public init(channel: UInt32, receptions: Int, trafficShare: Double) {
        self.channel = channel
        self.receptions = receptions
        self.trafficShare = trafficShare
    }
}

/// One bar of the mesh-wide hop-count distribution extra.
public struct HopBucketRow: Identifiable, Sendable, Equatable {
    public var id: Int {
        hops
    }

    public let hops: Int
    public let receptions: Int
    public let share: Double

    public init(hops: Int, receptions: Int, share: Double) {
        self.hops = hops
        self.receptions = receptions
        self.share = share
    }
}
