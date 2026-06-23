// PacketFilter — pure predicate over InspectedPacket (G6). Filters the inspector
// window by port, source/dest node, channel, and free text. All optional; an
// all-nil filter matches everything. Pure + Sendable so it's unit-tested directly
// and reused by the view model.

import Domain

public struct PacketFilter: Sendable, Equatable {
    /// Match only this port (compared by raw value so `.other` works too).
    public var port: MeshPort?
    /// Match only packets from this node (`from`).
    public var fromNode: UInt32?
    /// Match only this channel hash.
    public var channel: UInt32?
    /// Case-insensitive substring over the inspection's search haystack.
    public var text: String

    public init(
        port: MeshPort? = nil,
        fromNode: UInt32? = nil,
        channel: UInt32? = nil,
        text: String = ""
    ) {
        self.port = port
        self.fromNode = fromNode
        self.channel = channel
        self.text = text
    }

    /// True when every active criterion is satisfied (vacuously true if none set).
    public func matches(_ inspection: InspectedPacket) -> Bool {
        if let port, port.portNumRawValue != inspection.port.portNumRawValue { return false }
        if let fromNode, fromNode != inspection.from { return false }
        if let channel, channel != inspection.channel { return false }
        let trimmed = text.trimmingCharacters(in: [" "]).lowercased()
        if !trimmed.isEmpty, !inspection.searchHaystack.contains(trimmed) { return false }
        return true
    }

    /// Apply the filter to a list, preserving order.
    public func apply(to inspections: [InspectedPacket]) -> [InspectedPacket] {
        inspections.filter(matches)
    }

    /// True when an aggregate satisfies every active criterion. Port/node/channel
    /// are packet-wide (its representative carries them); the text criterion matches
    /// if *any* reception's haystack contains it (so a relay-only field still hits).
    public func matches(_ aggregate: AggregatedPacket) -> Bool {
        let probe = aggregate.representative
        if let port, port.portNumRawValue != probe.port.portNumRawValue { return false }
        if let fromNode, fromNode != probe.from { return false }
        if let channel, channel != probe.channel { return false }
        let trimmed = text.trimmingCharacters(in: [" "]).lowercased()
        if !trimmed.isEmpty {
            let anyHit = aggregate.receptions.contains { $0.searchHaystack.contains(trimmed) }
            if !anyHit { return false }
        }
        return true
    }

    /// Apply the filter to an aggregated list, preserving order.
    public func apply(to aggregates: [AggregatedPacket]) -> [AggregatedPacket] {
        aggregates.filter(matches)
    }

    /// Whether any criterion is active (for UI "clear" affordances).
    public var isActive: Bool {
        port != nil || fromNode != nil || channel != nil
            || !text.trimmingCharacters(in: [" "]).isEmpty
    }
}
