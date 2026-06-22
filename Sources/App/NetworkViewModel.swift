// NetworkViewModel — the composition seam for the live network view. Builds
// positioned NetworkNodes from the store (ignoring nodes without a position fix,
// SPEC §1) and feeds the decoded-packet stream into LivePacketTraceCollector to
// drive the animated traces. @MainActor @Observable; the build/ingest logic is
// unit-tested over an in-memory store.

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

    private var positions: [Int64: GeoPoint] = [:]
    private var collector: LivePacketTraceCollector
    private let store: MeshStore

    public init(store: MeshStore, maxPackets: Int = 12) {
        self.store = store
        collector = LivePacketTraceCollector(maxPackets: maxPackets)
    }

    /// The set of channel presets seen across the live nodes, sorted, for the map's
    /// channel filter control (Task 4).
    public var availablePresets: [ChannelPreset] {
        let seen = Set(presetByNode.values)
        return ChannelPreset.allCases.filter(seen.contains)
    }

    /// Load node positions from the store. Nodes without a position fix are ignored
    /// (they can't be drawn), per the spec.
    public func loadNodes() async throws {
        var built: [NetworkNode] = []
        var positionMap: [Int64: GeoPoint] = [:]
        for record in try await store.allNodes() {
            let fixes = try await store.positionFixes(forNode: record.node_num)
            guard let latest = fixes.max(by: { $0.t < $1.t }) else { continue }
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
        nodes = built
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
    public func ingest(_ packet: DecodedPacket) {
        collector.ingest(packet, arrivalClock: Self.animationClockNow())
        recordChannel(packet)
        traces = rebuiltTraces()
    }

    /// Resolve a packet's channel hash to a preset and stamp it both on the source node
    /// (live preset, for node colouring) and IMMUTABLY against the packet id (for trace
    /// filtering, Finding 20). The packet-id stamp is first-sight-wins so re-receptions of
    /// the same packet never move the trace; the node stamp tracks the latest channel.
    private func recordChannel(_ packet: DecodedPacket) {
        guard let preset = ChannelPreset.preset(forHash: packet.channel) else { return }
        if presetByPacket[packet.packetID] == nil { presetByPacket[packet.packetID] = preset }
        let nodeID = Int64(packet.from)
        guard presetByNode[nodeID] != preset else { return }
        presetByNode[nodeID] = preset
        nodes = nodes.map { node in
            node.id == nodeID ? node.withPreset(preset) : node
        }
    }

    /// Rebuild the live traces from the collector and stamp each with the channel it
    /// arrived on (Finding 20). Prunes `presetByPacket` to the live window so the map can
    /// never grow unbounded as packets are evicted.
    private func rebuiltTraces() -> [PacketTrace] {
        let built = collector.traces(positions: positions)
        let live = Set(built.map(\.id))
        presetByPacket = presetByPacket.filter { live.contains($0.key) }
        return built.map { $0.withPreset(presetByPacket[$0.id]) }
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
