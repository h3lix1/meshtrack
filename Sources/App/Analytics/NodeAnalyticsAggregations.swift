// NodeAnalyticsAggregations — the PURE, deterministic aggregation core for the
// per-node analytics deep-dive (Phase 7 G4). Every function here is total, takes
// plain inputs (telemetry/observation rows or decoded packets) and returns a
// plain value type, so the analytics views are dumb renderers and the maths is
// unit-tested independent of SwiftUI/MapKit/GRDB.
//
// Sources:
//   * SNR/RSSI distribution + hop histogram + hourly activity heatmap + peer
//     topology come from `ObservationRecord`s (rx_snr, rx_rssi, hop_start,
//     hop_limit, gateway_id, rx_time).
//   * Packet-type breakdown comes from decoded packets' `MeshPort` (the
//     observation table carries no port column, so the live feed supplies it via
//     the view-model's ingest seam, mirroring `NetworkViewModel.ingest`).

import Domain
import Persistence

// MARK: - SNR / RSSI distribution

/// One bucket of a value histogram: a half-open range `[lowerBound, upperBound)`
/// and how many samples fell inside it.
public struct HistogramBin: Sendable, Equatable, Identifiable {
    public let lowerBound: Double
    public let upperBound: Double
    public let count: Int

    public var id: Double {
        lowerBound
    }

    /// Bin centre, handy for axis labels.
    public var midpoint: Double {
        (lowerBound + upperBound) / 2
    }

    public init(lowerBound: Double, upperBound: Double, count: Int) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.count = count
    }
}

/// A signal-quality distribution: the binned histogram plus summary stats over the
/// non-nil samples (so the view can show "mean −7.2 dB over 412 receptions").
public struct SignalDistribution: Sendable, Equatable {
    public let bins: [HistogramBin]
    public let sampleCount: Int
    public let minValue: Double?
    public let maxValue: Double?
    public let mean: Double?

    public init(bins: [HistogramBin], sampleCount: Int, minValue: Double?, maxValue: Double?, mean: Double?) {
        self.bins = bins
        self.sampleCount = sampleCount
        self.minValue = minValue
        self.maxValue = maxValue
        self.mean = mean
    }

    public static let empty = SignalDistribution(
        bins: [], sampleCount: 0, minValue: nil, maxValue: nil, mean: nil
    )
}

public enum NodeAnalytics {
    /// Bin `values` into `binCount` equal-width buckets spanning [min, max].
    /// Returns `.empty` when there are no samples. A single distinct value (zero
    /// span) is widened to one unit so it still renders one populated bin.
    public static func distribution(of values: [Double], binCount: Int = 12) -> SignalDistribution {
        guard !values.isEmpty, binCount > 0 else { return .empty }
        let dataMin = values.min() ?? 0
        var high = values.max() ?? 0
        var low = dataMin
        if high - low < 1e-9 {
            // Degenerate single-value span — widen so the value lands mid-range.
            low -= 0.5
            high += 0.5
        }
        let span = high - low
        let width = span / Double(binCount)
        var counts = [Int](repeating: 0, count: binCount)
        for value in values {
            var index = Int((value - low) / width)
            if index < 0 { index = 0 }
            if index >= binCount { index = binCount - 1 }
            counts[index] += 1
        }
        let bins = counts.enumerated().map { offset, count in
            HistogramBin(
                lowerBound: low + Double(offset) * width,
                upperBound: low + Double(offset + 1) * width,
                count: count
            )
        }
        let sum = values.reduce(0, +)
        return SignalDistribution(
            bins: bins,
            sampleCount: values.count,
            minValue: dataMin,
            maxValue: values.max(),
            mean: sum / Double(values.count)
        )
    }

    /// SNR distribution over the observations that carry an `rx_snr`.
    public static func snrDistribution(
        observations: [ObservationRecord],
        binCount: Int = 12
    ) -> SignalDistribution {
        distribution(of: observations.compactMap(\.rx_snr), binCount: binCount)
    }

    /// RSSI distribution over the observations that carry an `rx_rssi`.
    public static func rssiDistribution(
        observations: [ObservationRecord],
        binCount: Int = 12
    ) -> SignalDistribution {
        distribution(of: observations.compactMap { $0.rx_rssi.map(Double.init) }, binCount: binCount)
    }

    // MARK: - Hop-count histogram

    /// Hops travelled for one observation = `hop_start − hop_limit`, when both are
    /// present and non-negative. `nil` otherwise (can't be inferred).
    public static func hopCount(_ observation: ObservationRecord) -> Int? {
        guard let start = observation.hop_start, let limit = observation.hop_limit else { return nil }
        let hops = start - limit
        return hops >= 0 ? hops : nil
    }

    /// Count of observations per hop count, dense from 0 to the max observed hop
    /// (so absent intermediate hop counts render as empty bars). Empty input → [].
    public static func hopHistogram(observations: [ObservationRecord]) -> [HopBucket] {
        let hops = observations.compactMap(hopCount)
        guard let maxHop = hops.max() else { return [] }
        var counts = [Int](repeating: 0, count: maxHop + 1)
        for hop in hops {
            counts[hop] += 1
        }
        return counts.enumerated().map { HopBucket(hops: $0.offset, count: $0.element) }
    }

    // MARK: - Peer / topology

    /// Which gateways/relays heard this node, ranked by reception count, with the
    /// average SNR per peer (for edge styling / weighting in the topology graph).
    public static func peerSummaries(observations: [ObservationRecord]) -> [PeerSummary] {
        var counts: [String: Int] = [:]
        var snrSums: [String: Double] = [:]
        var snrCounts: [String: Int] = [:]
        for observation in observations {
            let gateway = observation.gateway_id ?? "unknown"
            counts[gateway, default: 0] += 1
            if let snr = observation.rx_snr {
                snrSums[gateway, default: 0] += snr
                snrCounts[gateway, default: 0] += 1
            }
        }
        return counts
            .map { gateway, count in
                let snrCount = snrCounts[gateway] ?? 0
                let avgSNR = snrCount > 0 ? (snrSums[gateway] ?? 0) / Double(snrCount) : nil
                return PeerSummary(gatewayID: gateway, receptionCount: count, averageSNR: avgSNR)
            }
            // Most-heard first; stable tie-break by id so layout is deterministic.
            .sorted { lhs, rhs in
                lhs.receptionCount != rhs.receptionCount
                    ? lhs.receptionCount > rhs.receptionCount
                    : lhs.gatewayID < rhs.gatewayID
            }
    }

    // MARK: - Hourly activity heatmap

    /// Receptions bucketed by hour-of-day (0…23) in UTC. Always returns 24 slots
    /// so the heatmap is a fixed grid. `t` is nanoseconds since the Unix epoch.
    public static func hourlyActivity(observations: [ObservationRecord]) -> [HourBucket] {
        var counts = [Int](repeating: 0, count: 24)
        for observation in observations {
            let hour = hourOfDay(nanoseconds: observation.rx_time)
            counts[hour] += 1
        }
        return counts.enumerated().map { HourBucket(hour: $0.offset, count: $0.element) }
    }

    /// Hour-of-day (0…23, UTC) for a nanoseconds-since-epoch timestamp. Pure
    /// integer maths so it stays Foundation-free and deterministic.
    public static func hourOfDay(nanoseconds: Int64) -> Int {
        let secondsPerDay: Int64 = 86400
        let seconds = nanoseconds / 1_000_000_000
        // Floor-mod so pre-epoch timestamps still land in 0…86399.
        var secondsOfDay = seconds % secondsPerDay
        if secondsOfDay < 0 { secondsOfDay += secondsPerDay }
        return Int(secondsOfDay / 3600)
    }

    // MARK: - Packet-type breakdown

    /// Count of packets per `MeshPort`, ranked by count then by canonical port
    /// order, so the breakdown reads as a stable, descending list.
    public static func packetTypeBreakdown(packets: [DecodedPacket]) -> [PacketTypeCount] {
        // `MeshPort` is Equatable but not Hashable (Domain owns it), so key the
        // tally by the canonical raw port number and rebuild the port from it.
        var counts: [Int: Int] = [:]
        for packet in packets {
            counts[packet.port.portNumRawValue, default: 0] += 1
        }
        return counts
            .map { PacketTypeCount(port: MeshPort(portNumRawValue: $0.key), count: $0.value) }
            .sorted { lhs, rhs in
                lhs.count != rhs.count
                    ? lhs.count > rhs.count
                    : lhs.port.portNumRawValue < rhs.port.portNumRawValue
            }
    }
}

// MARK: - Value types

/// One bar of the hop-count histogram.
public struct HopBucket: Sendable, Equatable, Identifiable {
    public let hops: Int
    public let count: Int
    public var id: Int {
        hops
    }

    public init(hops: Int, count: Int) {
        self.hops = hops
        self.count = count
    }
}

/// A gateway/relay that heard the node, with weight + signal for the topology graph.
public struct PeerSummary: Sendable, Equatable, Identifiable {
    public let gatewayID: String
    public let receptionCount: Int
    public let averageSNR: Double?
    public var id: String {
        gatewayID
    }

    public init(gatewayID: String, receptionCount: Int, averageSNR: Double?) {
        self.gatewayID = gatewayID
        self.receptionCount = receptionCount
        self.averageSNR = averageSNR
    }
}

/// One cell of the 24-hour activity heatmap.
public struct HourBucket: Sendable, Equatable, Identifiable {
    public let hour: Int
    public let count: Int
    public var id: Int {
        hour
    }

    public init(hour: Int, count: Int) {
        self.hour = hour
        self.count = count
    }
}

/// One slice of the packet-type breakdown.
public struct PacketTypeCount: Sendable, Equatable, Identifiable {
    public let port: MeshPort
    public let count: Int
    public var id: Int {
        port.portNumRawValue
    }

    public init(port: MeshPort, count: Int) {
        self.port = port
        self.count = count
    }

    /// Human-readable port label for the legend.
    public var label: String {
        MeshPortLabel.name(port)
    }
}

/// Stable display names for `MeshPort` (used by the breakdown legend + tooltips).
public enum MeshPortLabel {
    public static func name(_ port: MeshPort) -> String {
        switch port {
        case .textMessage: "Text"
        case .position: "Position"
        case .nodeInfo: "Node Info"
        case .routing: "Routing"
        case .admin: "Admin"
        case .waypoint: "Waypoint"
        case .telemetry: "Telemetry"
        case .mapReport: "Map Report"
        case let .other(raw): "Port \(raw)"
        }
    }
}
