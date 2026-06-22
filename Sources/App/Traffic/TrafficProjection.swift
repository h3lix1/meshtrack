// TrafficProjection — pure functions turning a `TrafficAggregator` snapshot into
// the sorted, presentation-ready rows the screens render. Separated from the
// aggregator so the fold logic stays free of sorting/ranking policy, and from the
// view models so the ranking is unit-testable without SwiftUI.

import Domain

public enum TrafficProjection {
    /// Port rows sorted by RECEPTIONS descending (the channel occupancy each port is
    /// responsible for), tie-broken by raw port number for determinism.
    public static func portRows(_ aggregator: TrafficAggregator) -> [PortStatRow] {
        let total = max(aggregator.totalReceptions, 1)
        return aggregator.ports
            .map { raw, counters in
                PortStatRow(
                    descriptor: PortCatalog.descriptor(forRawValue: raw),
                    receptions: counters.receptions,
                    distinctPackets: counters.distinctPackets,
                    sourceNodeCount: counters.sourceNodes.count,
                    gatewayCount: counters.gateways.count,
                    maxHops: counters.maxHops,
                    trafficShare: Double(counters.receptions) / Double(total)
                )
            }
            .sorted { lhs, rhs in
                lhs.receptions != rhs.receptions
                    ? lhs.receptions > rhs.receptions
                    : lhs.descriptor.rawValue < rhs.descriptor.rawValue
            }
    }

    /// Offender rows ranked by traffic burden: a node's flood RECEPTIONS first (the
    /// load it actually puts on the mesh), tie-broken by emitted distinct packets,
    /// then spread, then node number. Capped to `limit` worst offenders.
    public static func offenderRows(_ aggregator: TrafficAggregator, limit: Int = 50) -> [OffenderRow] {
        let rows = aggregator.nodes.map { nodeNum, counters in
            OffenderRow(
                nodeNum: nodeNum,
                emitted: counters.emitted,
                receptions: counters.receptions,
                spread: counters.gateways.count,
                packetsPerMinute: packetsPerMinute(counters),
                dominantPort: dominantPort(counters)
            )
        }
        return Array(rows.sorted(by: offenderOrder).prefix(max(0, limit)))
    }

    /// The full why/how/when detail for one node, or `nil` if the node is unknown.
    /// Pure derivation over the per-node counters — see `OffenderDetail`.
    public static func offenderDetail(
        _ aggregator: TrafficAggregator,
        forNode nodeNum: UInt32
    ) -> OffenderDetail? {
        guard let counters = aggregator.nodes[nodeNum] else { return nil }
        return OffenderDetail(
            nodeNum: nodeNum,
            receptions: counters.receptions,
            emitted: counters.emitted,
            spread: counters.gateways.count,
            packetsPerMinute: packetsPerMinute(counters),
            dominantPort: dominantPort(counters),
            ports: portRows(for: counters),
            gateways: counters.gateways.sorted(),
            minHops: counters.minHops ?? 0,
            maxHops: counters.maxHops,
            firstSeen: counters.firstSeen,
            lastSeen: counters.lastSeen,
            activity: activityRows(for: counters)
        )
    }

    /// Per-port breakdown for one node, sorted by receptions descending (dominant
    /// first), tie-broken by raw port for determinism.
    static func portRows(for counters: NodeCounters) -> [OffenderPortRow] {
        let total = max(counters.receptions, 1)
        return counters.portReceptions
            .map { raw, receptions in
                OffenderPortRow(
                    descriptor: PortCatalog.descriptor(forRawValue: raw),
                    emitted: counters.portEmitted[raw] ?? 0,
                    receptions: receptions,
                    share: Double(receptions) / Double(total)
                )
            }
            .sorted { lhs, rhs in
                lhs.receptions != rhs.receptions
                    ? lhs.receptions > rhs.receptions
                    : lhs.descriptor.rawValue < rhs.descriptor.rawValue
            }
    }

    /// The minute-by-minute activity histogram for one node, ascending by minute.
    /// Gaps (silent minutes within the window) are filled with zero buckets so the
    /// sparkline reads as a true timeline rather than a compressed bar list.
    static func activityRows(for counters: NodeCounters) -> [ActivityBucketRow] {
        guard let last = counters.minuteBuckets.keys.max() else { return [] }
        return (0 ... last).map { minute in
            ActivityBucketRow(minute: minute, receptions: counters.minuteBuckets[minute] ?? 0)
        }
    }

    /// Busiest-channels extra: channel rows sorted by receptions descending.
    public static func channelRows(_ aggregator: TrafficAggregator) -> [ChannelTrafficRow] {
        let total = max(aggregator.totalReceptions, 1)
        return aggregator.channelReceptions
            .map { channel, receptions in
                ChannelTrafficRow(
                    channel: channel,
                    receptions: receptions,
                    trafficShare: Double(receptions) / Double(total)
                )
            }
            .sorted { lhs, rhs in
                lhs.receptions != rhs.receptions ? lhs.receptions > rhs.receptions : lhs.channel < rhs.channel
            }
    }

    /// Hop-distribution extra: one bar per hop count, ascending by hop count.
    public static func hopRows(_ aggregator: TrafficAggregator) -> [HopBucketRow] {
        let total = max(aggregator.totalReceptions, 1)
        return aggregator.hopHistogram
            .map { hops, receptions in
                HopBucketRow(hops: hops, receptions: receptions, share: Double(receptions) / Double(total))
            }
            .sorted { $0.hops < $1.hops }
    }

    // MARK: Ranking helpers

    private static func offenderOrder(_ lhs: OffenderRow, _ rhs: OffenderRow) -> Bool {
        if lhs.receptions != rhs.receptions { return lhs.receptions > rhs.receptions }
        if lhs.emitted != rhs.emitted { return lhs.emitted > rhs.emitted }
        if lhs.spread != rhs.spread { return lhs.spread > rhs.spread }
        return lhs.nodeNum < rhs.nodeNum
    }

    /// Receptions per minute over the node's observed window. A zero/degenerate window
    /// (single reception, or all at one instant) reports the raw reception count so a
    /// burst still ranks above a steady trickle.
    static func packetsPerMinute(_ counters: NodeCounters) -> Double {
        guard let first = counters.firstSeen, let last = counters.lastSeen else { return 0 }
        let minutes = last.secondsSince(first) / 60
        guard minutes > 0 else { return Double(counters.receptions) }
        return Double(counters.receptions) / minutes
    }

    /// The node's dominant port — the one with the most receptions, tie-broken low.
    static func dominantPort(_ counters: NodeCounters) -> PortDescriptor? {
        guard let raw = counters.portReceptions.max(by: { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
        })?.key else { return nil }
        return PortCatalog.descriptor(forRawValue: raw)
    }
}
