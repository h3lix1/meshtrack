// AggregatedPacket — one packet id's whole story across every reception (G6,
// item 10). The same logical packet is heard many times (via different gateways
// and relays), so the inspector's master list shows one row PER PACKET ID and the
// detail pane unfolds every reception underneath it: who received it, the relay
// byte, hop count, SNR/RSSI, channel, and the per-reception latency journey.
//
// Pure + Sendable so the view model, the views, and the unit tests share one
// computation. Latency is sanitised here — implausible (skewed-RTC) receptions
// never reach the aggregate's stats. SwiftUI lives elsewhere.

import Domain

/// All receptions of one packet id, plus the rollups the inspector renders.
public struct AggregatedPacket: Identifiable, Sendable, Equatable {
    /// The shared packet id — the aggregate's identity.
    public let packetID: UInt32
    /// Every reception of this id, newest-first (the order they were ingested).
    public let receptions: [InspectedPacket]

    public var id: UInt32 {
        packetID
    }

    /// - Parameter receptions: the receptions of a single packet id. Must be
    ///   non-empty and all share `packetID` (the grouping guarantees both).
    public init(packetID: UInt32, receptions: [InspectedPacket]) {
        self.packetID = packetID
        self.receptions = receptions
    }

    /// The newest reception — the representative used for shared identity fields
    /// (from/to/port/channel) and as the default detail focus.
    public var representative: InspectedPacket {
        // receptions is guaranteed non-empty by `group(_:)`; fall back defensively.
        receptions.first ?? receptions[receptions.startIndex]
    }
}

// MARK: - Shared identity (delegated to the representative reception)

public extension AggregatedPacket {
    var from: UInt32 {
        representative.from
    }

    var to: UInt32 {
        representative.to
    }

    var fromHex: String {
        representative.fromHex
    }

    var toHex: String {
        representative.toHex
    }

    var port: MeshPort {
        representative.port
    }

    var portName: String {
        representative.portName
    }

    var channel: UInt32 {
        representative.channel
    }

    var wasEncrypted: Bool {
        representative.wasEncrypted
    }
}

// MARK: - Counts & ranges across receptions

public extension AggregatedPacket {
    /// How many times this id was heard.
    var receptionCount: Int {
        receptions.count
    }

    /// Distinct gateways that uplinked this id (those with a known gateway).
    var distinctGateways: [UInt32] {
        var seen = Set<UInt32>()
        return receptions.compactMap { reception in
            guard let gateway = reception.packet.gatewayID else { return nil }
            return seen.insert(gateway).inserted ? gateway : nil
        }
    }

    var distinctGatewayCount: Int {
        distinctGateways.count
    }

    /// The hop counts seen across receptions (a packet relayed differently can
    /// arrive with different hop counts). Sorted ascending.
    var hopCounts: [Int] {
        receptions.compactMap(\.hops).sorted()
    }

    /// `min…max` hop range, or a single value, or `nil` when no hop data.
    var hopRangeText: String? {
        let hops = hopCounts
        guard let low = hops.first, let high = hops.last else { return nil }
        return low == high ? "\(low)" : "\(low)–\(high)"
    }
}

// MARK: - Grouping

public extension AggregatedPacket {
    /// Group receptions into one aggregate per packet id, preserving the input
    /// order of *first appearance* (so a newest-first window stays newest-first).
    /// Within each aggregate, receptions keep their input order.
    static func group(_ receptions: [InspectedPacket]) -> [AggregatedPacket] {
        var order: [UInt32] = []
        var byID: [UInt32: [InspectedPacket]] = [:]
        for reception in receptions {
            let key = reception.packetID
            if byID[key] == nil { order.append(key) }
            byID[key, default: []].append(reception)
        }
        return order.map { key in
            AggregatedPacket(packetID: key, receptions: byID[key] ?? [])
        }
    }
}
