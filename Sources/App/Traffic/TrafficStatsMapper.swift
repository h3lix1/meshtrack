// TrafficStatsMapper — pure mapping from an in-memory `TrafficAggregator` snapshot
// to the durable Persistence record types (`NodeTrafficStatRecord` /
// `PortTrafficStatRecord`). Kept pure + Sendable so the view models can snapshot off
// the main actor, and so the mapping is unit-testable without a database.

import Domain
import Persistence

public enum TrafficStatsMapper {
    /// Map every per-port counter to a durable `PortTrafficStatRecord`.
    public static func portRecords(_ aggregator: TrafficAggregator) -> [PortTrafficStatRecord] {
        aggregator.ports.map { raw, counters in
            PortTrafficStatRecord(
                port: Int64(raw),
                receptions: Int64(counters.receptions),
                distinct_packets: Int64(counters.distinctPackets),
                source_nodes: Int64(counters.sourceNodes.count),
                gateways: Int64(counters.gateways.count),
                max_hops: Int64(counters.maxHops)
            )
        }
    }

    /// Map every per-node counter to a durable `NodeTrafficStatRecord`.
    public static func nodeRecords(_ aggregator: TrafficAggregator) -> [NodeTrafficStatRecord] {
        aggregator.nodes.map { nodeNum, counters in
            NodeTrafficStatRecord(
                node_num: Int64(nodeNum),
                emitted: Int64(counters.emitted),
                receptions: Int64(counters.receptions),
                spread: Int64(counters.gateways.count),
                first_seen_at: counters.firstSeen?.nanosecondsSinceEpoch ?? 0,
                last_seen_at: counters.lastSeen?.nanosecondsSinceEpoch ?? 0,
                dominant_port: TrafficProjection.dominantPort(counters).map { Int64($0.rawValue) }
            )
        }
    }
}
