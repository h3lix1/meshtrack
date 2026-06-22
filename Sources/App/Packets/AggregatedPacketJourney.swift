// AggregatedPacketJourney — the per-id rollups the detail pane unfolds: the
// distinct paths a packet took (relay/gateway combinations) and its latency
// journey across receptions (min/median/spread, first-heard vs last-heard).
//
// Split out of AggregatedPacket to keep each type small. Pure + Sendable; latency
// is sanitised (only plausible receptions contribute) so skewed-RTC garbage never
// reaches the spread or the min/median.

import Domain

/// One distinct path a packet took: the relay byte + the gateway that uplinked
/// it, with how many receptions arrived via that exact combination.
public struct PacketPath: Identifiable, Sendable, Equatable {
    /// Last byte of the previous hop (`relay_node`), or `nil` when absent.
    public let relayByte: UInt8?
    /// The uplinking gateway node id, or `nil` when absent.
    public let gatewayID: UInt32?
    /// How many receptions arrived via this exact relay+gateway combination.
    public let count: Int

    public var id: String {
        let relay = relayByte.map { String($0) } ?? "—"
        let gateway = gatewayID.map { String($0) } ?? "—"
        return "\(relay)/\(gateway)"
    }

    public init(relayByte: UInt8?, gatewayID: UInt32?, count: Int) {
        self.relayByte = relayByte
        self.gatewayID = gatewayID
        self.count = count
    }

    public var relayText: String {
        relayByte.map { String(format: "0x%02x", $0) } ?? "—"
    }

    public var gatewayText: String {
        gatewayID.map(InspectedPacket.hexID) ?? "—"
    }
}

public extension AggregatedPacket {
    /// The distinct relay+gateway combinations this id arrived through, ordered by
    /// reception count (busiest path first), ties broken by first appearance.
    var paths: [PacketPath] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var spec: [String: (UInt8?, UInt32?)] = [:]
        for reception in receptions {
            let relay = reception.packet.relayNode
            let gateway = reception.packet.gatewayID
            let key = "\(relay.map(String.init) ?? "—")/\(gateway.map(String.init) ?? "—")"
            if counts[key] == nil {
                order.append(key)
                spec[key] = (relay, gateway)
            }
            counts[key, default: 0] += 1
        }
        let unsorted = order.map { key -> PacketPath in
            let pair = spec[key] ?? (nil, nil)
            return PacketPath(relayByte: pair.0, gatewayID: pair.1, count: counts[key] ?? 0)
        }
        return unsorted.enumerated()
            .sorted { lhs, rhs in
                lhs.element.count != rhs.element.count
                    ? lhs.element.count > rhs.element.count
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    var distinctPathCount: Int {
        paths.count
    }
}

/// The latency journey of a packet id across its receptions — only plausible
/// (sane-RTC) receptions contribute. When none are plausible, `.unavailable`.
public struct PacketLatencyJourney: Sendable, Equatable {
    /// Plausible per-reception latencies in ms, in reception (newest-first) order.
    public let plausibleMillis: [Int]
    /// How many receptions had an implausible / unavailable latency (excluded).
    public let excludedCount: Int

    public init(plausibleMillis: [Int], excludedCount: Int) {
        self.plausibleMillis = plausibleMillis
        self.excludedCount = excludedCount
    }

    public var isEmpty: Bool {
        plausibleMillis.isEmpty
    }

    public var minMillis: Int? {
        plausibleMillis.min()
    }

    public var maxMillis: Int? {
        plausibleMillis.max()
    }

    /// Spread = max − min across plausible receptions.
    public var spreadMillis: Int? {
        guard let low = minMillis, let high = maxMillis else { return nil }
        return high - low
    }

    /// Lower-rank nearest-value median of the plausible latencies.
    public var medianMillis: Int? {
        let sorted = plausibleMillis.sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted[(sorted.count - 1) / 2]
    }
}

public extension AggregatedPacket {
    /// The latency journey across receptions (plausible only).
    var latencyJourney: PacketLatencyJourney {
        var plausible: [Int] = []
        var excluded = 0
        for reception in receptions { // newest-first preserved
            if let millis = reception.plausibleLatencyMillis {
                plausible.append(millis)
            } else {
                excluded += 1
            }
        }
        return PacketLatencyJourney(plausibleMillis: plausible, excludedCount: excluded)
    }

    /// The latency of the *most recently heard* reception, plausible only — the
    /// single value the master row shows.
    var firstHeardLatencyMillis: Int? {
        receptions.last?.plausibleLatencyMillis
    }

    /// The plausible latency of the newest reception — "last heard".
    var lastHeardLatencyMillis: Int? {
        receptions.first?.plausibleLatencyMillis
    }
}
