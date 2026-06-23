// OffendersViewModel — the composition seam for the Largest-offenders screen
// (item 12). Folds the live decoded-packet stream into a pure `TrafficAggregator`
// via an `ingest(_:)` seam (mirroring NetworkViewModel), and projects ranked
// `OffenderRow`s. @MainActor @Observable; the counting + ranking live in pure,
// unit-tested helpers, so this is a thin coordinator.
//
// PERSISTENCE: the running per-node aggregate is snapshotted into `node_traffic_stat`
// every `persistInterval` receptions and re-seeded on launch, so the offenders
// ranking survives across sessions. The store is optional (previews / snapshots run
// with no I/O); when wired, `loadPersisted()` hydrates `persistedRows` for a
// cold-start ranking before any live packets arrive.

import Domain
import Foundation
import Observation
import Persistence

@Observable
@MainActor
public final class OffendersViewModel {
    /// The live, in-session offender ranking (worst first) — the screen's main table.
    public private(set) var rows: [OffenderRow] = []
    /// The all-time ranking loaded from the durable store at launch, before/below the
    /// live one (so the screen has a ranking even on a cold start). Empty without a store.
    public private(set) var persistedRows: [OffenderRow] = []
    /// Total receptions folded this session (headline + context).
    public private(set) var totalReceptions = 0
    /// The node whose full why/how/when detail is open, or `nil` for the ranking list.
    /// Master/detail selection within the section; set by tapping a row.
    public private(set) var selectedNode: UInt32?

    private var aggregator = TrafficAggregator()
    private let store: MeshStore?
    private let limit: Int
    private let persistInterval: Int
    private var sinceLastPersist = 0

    /// - Parameters:
    ///   - store: shared store for durable snapshots + the all-time ranking; `nil`
    ///     for previews / snapshots.
    ///   - limit: how many worst offenders to surface.
    ///   - persistInterval: receptions between durable snapshots.
    public init(store: MeshStore? = nil, limit: Int = 50, persistInterval: Int = 200) {
        self.store = store
        self.limit = max(1, limit)
        self.persistInterval = max(1, persistInterval)
    }

    // MARK: Ingest seam

    /// Fold one decoded packet in and re-rank. O(1) fold; the projection sorts the
    /// per-node map and caps to `limit`.
    public func ingest(_ packet: DecodedPacket) {
        aggregator.fold(packet)
        rows = TrafficProjection.offenderRows(aggregator, limit: limit)
        totalReceptions = aggregator.totalReceptions
        sinceLastPersist += 1
        if sinceLastPersist >= persistInterval {
            sinceLastPersist = 0
            persist()
        }
    }

    // MARK: Selection (master/detail)

    /// The live why/how/when detail for the selected node, recomputed from the current
    /// aggregate each access, or `nil` when nothing is selected (or the node has aged
    /// out of the in-memory aggregate — e.g. a persisted-only row).
    public var selectedDetail: OffenderDetail? {
        guard let selectedNode else { return nil }
        return aggregator.detail(forNode: selectedNode)
    }

    /// Open the detail for a node (tapping a row). Re-selecting the open node is a
    /// no-op; pass a different node to switch.
    public func select(nodeNum: UInt32) {
        selectedNode = nodeNum
    }

    /// Return to the ranking list (the detail panel's back/close affordance).
    public func clearSelection() {
        selectedNode = nil
    }

    // MARK: Reset

    /// Wipe ALL offender metrics so the ranking starts fresh: both the in-session
    /// aggregate (cleared synchronously here so the UI empties instantly) AND the
    /// durable all-time ranking in `node_traffic_stat` (cleared via a fire-and-forget
    /// task; a no-op when there's no store, e.g. previews/snapshots).
    public func reset() {
        aggregator = TrafficAggregator()
        rows = []
        persistedRows = []
        totalReceptions = 0
        selectedNode = nil
        sinceLastPersist = 0
        Task { try? await store?.clearNodeTraffic() }
    }

    // MARK: Persistence

    /// Hydrate the all-time ranking from `node_traffic_stat` at launch.
    public func loadPersisted() async {
        guard let store else { return }
        let records = await (try? store.loadNodeTraffic(limit: limit)) ?? []
        persistedRows = records.map(OffendersViewModel.row(from:))
    }

    /// Snapshot the current per-node aggregate into `node_traffic_stat`.
    private func persist() {
        guard let store else { return }
        let records = TrafficStatsMapper.nodeRecords(aggregator)
        Task { try? await store.saveTrafficStats(nodes: records, ports: []) }
    }

    /// Flush now (e.g. before teardown). Awaitable for deterministic tests.
    public func flush() async {
        guard let store else { return }
        try? await store.saveTrafficStats(nodes: TrafficStatsMapper.nodeRecords(aggregator), ports: [])
    }

    /// Project a durable record back into an `OffenderRow` for the all-time table.
    private static func row(from record: NodeTrafficStatRecord) -> OffenderRow {
        let first = Instant(nanosecondsSinceEpoch: record.first_seen_at)
        let last = Instant(nanosecondsSinceEpoch: record.last_seen_at)
        let minutes = last.secondsSince(first) / 60
        let perMinute = minutes > 0 ? Double(record.receptions) / minutes : Double(record.receptions)
        return OffenderRow(
            nodeNum: UInt32(truncatingIfNeeded: record.node_num),
            emitted: Int(record.emitted),
            receptions: Int(record.receptions),
            spread: Int(record.spread),
            packetsPerMinute: perMinute,
            dominantPort: record.dominant_port.map { PortCatalog.descriptor(forRawValue: Int($0)) }
        )
    }
}

public extension OffendersViewModel {
    /// A preview/snapshot view model pre-seeded with sample receptions (no store).
    static func sample() -> OffendersViewModel {
        let model = OffendersViewModel()
        for packet in TrafficSampleData.packets {
            model.ingest(packet)
        }
        return model
    }
}
