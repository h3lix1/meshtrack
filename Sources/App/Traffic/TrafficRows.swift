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

/// One port's contribution to a single node's traffic, for the offender detail panel.
public struct OffenderPortRow: Identifiable, Sendable, Equatable {
    public var id: Int {
        descriptor.rawValue
    }

    public let descriptor: PortDescriptor
    /// Distinct logical packets this node originated on this port.
    public let emitted: Int
    /// Flood receptions attributed to this node on this port.
    public let receptions: Int
    /// Share of this node's RECEPTIONS carried by this port, in 0...1.
    public let share: Double

    public init(descriptor: PortDescriptor, emitted: Int, receptions: Int, share: Double) {
        self.descriptor = descriptor
        self.emitted = emitted
        self.receptions = receptions
        self.share = share
    }

    /// Whole-percent string for the share, e.g. "37%".
    public var sharePercentLabel: String {
        "\(Int((share * 100).rounded()))%"
    }
}

/// One whole-minute activity bucket for a node, driving the detail panel's sparkline.
public struct ActivityBucketRow: Identifiable, Sendable, Equatable {
    public var id: Int {
        minute
    }

    /// Minute index since the node was first heard (0 = first minute).
    public let minute: Int
    public let receptions: Int

    public init(minute: Int, receptions: Int) {
        self.minute = minute
        self.receptions = receptions
    }
}

/// The full why/how/when picture for one offender node — the master/detail payload.
/// Pure + Sendable so it is derived off the main actor and unit-tested without SwiftUI.
public struct OffenderDetail: Identifiable, Sendable, Equatable {
    public var id: UInt32 {
        nodeNum
    }

    public let nodeNum: UInt32
    // WHY
    public let receptions: Int
    public let emitted: Int
    public let spread: Int
    public let packetsPerMinute: Double
    public let dominantPort: PortDescriptor?
    // HOW
    public let ports: [OffenderPortRow]
    public let gateways: [UInt32]
    public let minHops: Int
    public let maxHops: Int
    // WHEN
    public let firstSeen: Instant?
    public let lastSeen: Instant?
    public let activity: [ActivityBucketRow]

    public init(
        nodeNum: UInt32,
        receptions: Int,
        emitted: Int,
        spread: Int,
        packetsPerMinute: Double,
        dominantPort: PortDescriptor?,
        ports: [OffenderPortRow],
        gateways: [UInt32],
        minHops: Int,
        maxHops: Int,
        firstSeen: Instant?,
        lastSeen: Instant?,
        activity: [ActivityBucketRow]
    ) {
        self.nodeNum = nodeNum
        self.receptions = receptions
        self.emitted = emitted
        self.spread = spread
        self.packetsPerMinute = packetsPerMinute
        self.dominantPort = dominantPort
        self.ports = ports
        self.gateways = gateways
        self.minHops = minHops
        self.maxHops = maxHops
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.activity = activity
    }

    /// The `!aabbccdd` node id for display.
    public var hexID: String {
        NodeID.hex(nodeNum)
    }

    /// Observed-window length in seconds (0 if a single instant / no data).
    public var windowSeconds: Double {
        guard let firstSeen, let lastSeen else { return 0 }
        return max(0, lastSeen.secondsSince(firstSeen))
    }

    /// The hop range as a compact label, e.g. "1–3" or "2" when min == max.
    public var hopRangeLabel: String {
        minHops == maxHops ? "\(maxHops)" : "\(minHops)–\(maxHops)"
    }

    /// Peak receptions in any one minute bucket (the sparkline's full-height scale).
    public var peakActivity: Int {
        activity.map(\.receptions).max() ?? 0
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
