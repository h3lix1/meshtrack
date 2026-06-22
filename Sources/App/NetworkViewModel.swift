// NetworkViewModel — the composition seam for the live network view. Builds
// positioned NetworkNodes from the store (ignoring nodes without a position fix,
// SPEC §1) and feeds the decoded-packet stream into LivePacketTraceCollector to
// drive the animated traces. @MainActor @Observable; the build/ingest logic is
// unit-tested over an in-memory store.
//
// Performance (Phase 10): the load and the live ingest were the two hot paths.
//   - loadNodes() used an N+1 store pattern (allNodes() then positionFixes(forNode:)
//     once per node, serially); it now issues ONE batched `latestPositionFixes()`
//     query and joins in memory.
//   - ingest() rebuilt EVERY trace and re-`map`ped the whole `nodes` array on every
//     single packet. It now updates the source node's preset in O(1) via a node-index
//     and COALESCES trace rebuilds: a packet marks the traces dirty and schedules a
//     single sub-frame flush, so a burst of packets collapses to one rebuild instead
//     of one-per-packet. The pure, CPU-bound trace construction runs OFF the main
//     actor (a detached task over Sendable snapshots) and only hops back to publish.
// The observable outputs (`nodes`, `traces`, `presetByNode`, `availablePresets`) are
// byte-identical to the old eager path — only the scheduling changed.

import Domain
import Foundation
import Observation
import Persistence

@Observable
@MainActor
public final class NetworkViewModel {
    public private(set) var nodes: [NetworkNode] = []
    public private(set) var traces: [PacketTrace] = []

    /// The channel preset each node's live packets last arrived on, by node id (Task 4).
    public private(set) var presetByNode: [Int64: ChannelPreset] = [:]

    /// The channel preset each WINDOWED packet arrived on, by packet id, captured
    /// immutably at ingest (Finding 20). Unlike `presetByNode` this is never rewritten
    /// when the source node later transmits elsewhere, so each trace keeps the channel it
    /// actually arrived on. Pruned to the live trace window so it can't grow unbounded.
    private var presetByPacket: [UInt32: ChannelPreset] = [:]

    /// Index of `nodes` by node id, so the per-packet preset stamp is an O(1) lookup +
    /// single-element replacement instead of an O(n) `nodes.map` on every packet.
    private var nodeIndexByID: [Int64: Int] = [:]

    private var positions: [Int64: GeoPoint] = [:]
    private var collector: LivePacketTraceCollector
    private let store: MeshStore

    /// How long ingest waits before flushing a coalesced trace rebuild. A burst of
    /// packets arriving inside this window collapses to ONE rebuild. Kept below a frame
    /// (1/60 s) so the overlay — which redraws every animation tick and only reads
    /// `traces` — never shows stale data the eye can catch. Configurable (and settable to
    /// 0) for deterministic tests.
    private let coalesceInterval: Duration

    /// The in-flight coalesced rebuild, if any. A second ingest inside the window does
    /// not schedule a second task; it just relies on this one, which reads the LATEST
    /// collector/positions when it fires.
    private var pendingRebuild: Task<Void, Never>?

    public init(store: MeshStore, maxPackets: Int = 12, coalesceInterval: Duration = .milliseconds(8)) {
        self.store = store
        self.coalesceInterval = coalesceInterval
        collector = LivePacketTraceCollector(maxPackets: maxPackets)
    }

    // No `deinit` cancel: the pending rebuild captures `[weak self]`, so once the model
    // deallocates the in-flight task's `self` is nil and it bails on its next hop — and a
    // `deinit` can't touch the @MainActor-isolated `pendingRebuild` anyway.

    /// The set of channel presets seen across the live nodes, sorted, for the map's
    /// channel filter control (Task 4).
    public var availablePresets: [ChannelPreset] {
        let seen = Set(presetByNode.values)
        return ChannelPreset.allCases.filter(seen.contains)
    }

    /// Load node positions from the store. Nodes without a position fix are ignored
    /// (they can't be drawn), per the spec.
    ///
    /// One batched `latestPositionFixes()` round-trip replaces the previous N+1 pattern
    /// (a `positionFixes(forNode:)` call per node, serially), so a populated mesh loads
    /// in a single query instead of one-per-node.
    public func loadNodes() async throws {
        async let nodeRecords = store.allNodes()
        async let latestFixes = store.latestPositionFixes()
        let (records, fixes) = try await (nodeRecords, latestFixes)

        var built: [NetworkNode] = []
        var positionMap: [Int64: GeoPoint] = [:]
        built.reserveCapacity(records.count)
        positionMap.reserveCapacity(records.count)
        for record in records {
            guard let latest = fixes[record.node_num] else { continue }
            let geo = GeoPoint(latitude: latest.lat, longitude: latest.lon)
            positionMap[record.node_num] = geo
            built.append(NetworkNode(
                id: record.node_num,
                name: Self.displayName(record),
                position: geo,
                hopsFromGateway: 0,
                isGateway: record.node_class == .gateway,
                preset: presetByNode[record.node_num]
            ))
        }
        setNodes(built)
        positions = positionMap
        traces = rebuiltTraces()
    }

    /// Feed one decoded packet into the live trace animation.
    ///
    /// The arrival is stamped with the current animation-clock instant
    /// (`Date.timeIntervalSinceReferenceDate`, the same clock the overlay's
    /// `TimelineView(.animation)` ticks on), so each new packet's hops animate from
    /// source toward the gateway starting now (Task 2).
    ///
    /// It also records the channel the packet arrived on against its source node, so
    /// the map can filter by channel preset (Task 4).
    ///
    /// The trace rebuild is COALESCED, not run inline: the synchronous work here is O(1)
    /// (fold into the collector, stamp the source node's preset via the index), and the
    /// expensive `traces()` reconstruction is scheduled once per `coalesceInterval`. A
    /// burst of packets therefore costs ONE rebuild, not one-per-packet.
    public func ingest(_ packet: DecodedPacket) {
        collector.ingest(packet, arrivalClock: Self.animationClockNow())
        recordChannel(packet)
        scheduleTraceRebuild()
    }

    /// Resolve a packet's channel hash to a preset and stamp it both on the source node
    /// (live preset, for node colouring) and IMMUTABLY against the packet id (for trace
    /// filtering, Finding 20). The packet-id stamp is first-sight-wins so re-receptions of
    /// the same packet never move the trace; the node stamp tracks the latest channel.
    ///
    /// The node stamp is an O(1) index lookup + single-element replacement, not an O(n)
    /// `nodes.map` over the whole array on every packet.
    private func recordChannel(_ packet: DecodedPacket) {
        guard let preset = ChannelPreset.preset(forHash: packet.channel) else { return }
        if presetByPacket[packet.packetID] == nil { presetByPacket[packet.packetID] = preset }
        let nodeID = Int64(packet.from)
        guard presetByNode[nodeID] != preset else { return }
        presetByNode[nodeID] = preset
        if let index = nodeIndexByID[nodeID] {
            nodes[index] = nodes[index].withPreset(preset)
        }
    }

    /// Replace `nodes` and rebuild the id→index map in lock-step, so the two never drift.
    private func setNodes(_ newNodes: [NetworkNode]) {
        nodes = newNodes
        nodeIndexByID = Dictionary(
            uniqueKeysWithValues: newNodes.enumerated().map { ($1.id, $0) }
        )
    }

    // MARK: Coalesced trace rebuild

    /// Schedule a single coalesced rebuild of the live traces. If one is already pending,
    /// this is a no-op — the in-flight task will read the latest collector/positions when
    /// it fires, so it already covers this packet. With a zero interval the rebuild still
    /// hops through a task (one `Task.yield`) so same-tick bursts collapse to one rebuild.
    private func scheduleTraceRebuild() {
        guard pendingRebuild == nil else { return }
        let interval = coalesceInterval
        pendingRebuild = Task { [weak self] in
            if interval > .zero {
                try? await Task.sleep(for: interval)
            } else {
                await Task.yield()
            }
            guard let self, !Task.isCancelled else { return }
            pendingRebuild = nil
            await flushTraceRebuild()
        }
    }

    /// Rebuild the traces from the CURRENT collector/positions and publish them.
    ///
    /// The pure, CPU-bound reconstruction (`collector.traces(positions:)`) runs OFF the
    /// main actor — a detached task over Sendable snapshots of the collector and the
    /// position map — so a large window doesn't block UI/ingest. Only the cheap
    /// `presetByPacket` prune + stamp and the `@Observable` publish happen back here.
    private func flushTraceRebuild() async {
        let collectorSnapshot = collector
        let positionsSnapshot = positions
        let built = await Task.detached {
            collectorSnapshot.traces(positions: positionsSnapshot)
        }.value
        traces = stamped(built)
    }

    /// Rebuild the live traces from the collector synchronously (the load path, where the
    /// caller is already off the hot per-packet loop and wants the result immediately).
    private func rebuiltTraces() -> [PacketTrace] {
        stamped(collector.traces(positions: positions))
    }

    /// Stamp each freshly-built trace with the channel it arrived on (Finding 20) and
    /// prune `presetByPacket` to the live window so the map can never grow unbounded as
    /// packets are evicted.
    private func stamped(_ built: [PacketTrace]) -> [PacketTrace] {
        let live = Set(built.map(\.id))
        presetByPacket = presetByPacket.filter { live.contains($0.key) }
        return built.map { $0.withPreset(presetByPacket[$0.id]) }
    }

    /// Force any pending coalesced rebuild to complete now and publish, then return. Used
    /// by tests (and any caller that needs `traces` settled synchronously) to make the
    /// otherwise-debounced ingest deterministic.
    func flushPendingTraces() async {
        pendingRebuild?.cancel()
        pendingRebuild = nil
        await flushTraceRebuild()
    }

    /// The current value of the overlay's animation clock: seconds since the reference
    /// date, matching `TimelineView(.animation)`'s `date.timeIntervalSinceReferenceDate`.
    nonisolated static func animationClockNow() -> Double {
        Date().timeIntervalSinceReferenceDate
    }

    nonisolated static func displayName(_ record: NodeRecord) -> String {
        record.short_name ?? record.long_name ?? record.hexid
            ?? NodeID.hex(UInt32(truncatingIfNeeded: record.node_num))
    }
}
