// PortStatsViewModel — the composition seam for the Port-numbers screen (item 11).
// Folds the live decoded-packet stream into a pure `TrafficAggregator` via an
// `ingest(_:)` seam (mirroring NetworkViewModel / PacketInspectorViewModel), and
// projects sorted `PortStatRow`s for the view. @MainActor @Observable; all the
// counting + ranking is in pure, unit-tested helpers (`TrafficAggregator` /
// `TrafficProjection`), so this stays a thin coordinator.
//
// PERSISTENCE: every `persistInterval` receptions, the running aggregate is
// snapshotted into `port_traffic_stat` (and re-loadable on launch) through the new
// `Store+TrafficStats` extension, so the picture survives a relaunch. The store is
// optional so previews / snapshots run with no I/O.

import Domain
import Foundation
import Observation
import Persistence

@Observable
@MainActor
public final class PortStatsViewModel {
    /// Port rows, sorted by traffic (receptions) descending — the screen's table.
    public private(set) var rows: [PortStatRow] = []
    /// Busiest-channels extra, sorted by receptions descending.
    public private(set) var channels: [ChannelTrafficRow] = []
    /// Mesh-wide hop-count distribution extra, ascending by hop count.
    public private(set) var hops: [HopBucketRow] = []
    /// Total receptions folded so far (the screen's headline + share denominator).
    public private(set) var totalReceptions = 0
    /// Distinct logical packets folded so far (counting-policy companion to the above).
    public private(set) var totalDistinctPackets = 0

    private var aggregator = TrafficAggregator()
    private let store: MeshStore?
    private let persistInterval: Int
    private var sinceLastPersist = 0

    /// - Parameters:
    ///   - store: the shared store for snapshotting/loading durable counters; `nil`
    ///     for previews / snapshot fixtures (no I/O).
    ///   - persistInterval: how many receptions between durable snapshots.
    public init(store: MeshStore? = nil, persistInterval: Int = 200) {
        self.store = store
        self.persistInterval = max(1, persistInterval)
    }

    // MARK: Ingest seam

    /// Fold one decoded packet in and re-project the rows. The fold is O(1); the
    /// projection is over the small per-port/-channel maps, so this is cheap enough
    /// to run inline per packet for a live table.
    public func ingest(_ packet: DecodedPacket) {
        aggregator.fold(packet)
        reproject()
        sinceLastPersist += 1
        if sinceLastPersist >= persistInterval {
            sinceLastPersist = 0
            persist()
        }
    }

    /// Re-derive the published rows/totals from the current aggregate.
    private func reproject() {
        rows = TrafficProjection.portRows(aggregator)
        channels = TrafficProjection.channelRows(aggregator)
        hops = TrafficProjection.hopRows(aggregator)
        totalReceptions = aggregator.totalReceptions
        totalDistinctPackets = aggregator.totalDistinctPackets
    }

    // MARK: Persistence

    /// Snapshot the current per-port aggregate into `port_traffic_stat`. Fire-and-
    /// forget; a failed write never disturbs the live UI.
    private func persist() {
        guard let store else { return }
        let records = TrafficStatsMapper.portRecords(aggregator)
        Task { try? await store.saveTrafficStats(nodes: [], ports: records) }
    }

    /// Flush the running aggregate to the store now (e.g. before teardown). Awaitable
    /// for deterministic tests.
    public func flush() async {
        guard let store else { return }
        try? await store.saveTrafficStats(nodes: [], ports: TrafficStatsMapper.portRecords(aggregator))
    }
}

public extension PortStatsViewModel {
    /// A preview/snapshot view model pre-seeded with sample receptions (no store).
    static func sample() -> PortStatsViewModel {
        let model = PortStatsViewModel()
        for packet in TrafficSampleData.packets {
            model.ingest(packet)
        }
        return model
    }
}
