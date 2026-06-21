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

    private var positions: [Int64: GeoPoint] = [:]
    private var collector: LivePacketTraceCollector
    private let store: MeshStore

    public init(store: MeshStore, maxPackets: Int = 12) {
        self.store = store
        collector = LivePacketTraceCollector(maxPackets: maxPackets)
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
                isGateway: record.node_class == .gateway
            ))
        }
        nodes = built
        positions = positionMap
        traces = collector.traces(positions: positions)
    }

    /// Feed one decoded packet into the live trace animation.
    ///
    /// The arrival is stamped with the current animation-clock instant
    /// (`Date.timeIntervalSinceReferenceDate`, the same clock the overlay's
    /// `TimelineView(.animation)` ticks on), so each new packet's hops animate from
    /// source toward the gateway starting now (Task 2).
    public func ingest(_ packet: DecodedPacket) {
        collector.ingest(packet, arrivalClock: Self.animationClockNow())
        traces = collector.traces(positions: positions)
    }

    /// The current value of the overlay's animation clock: seconds since the reference
    /// date, matching `TimelineView(.animation)`'s `date.timeIntervalSinceReferenceDate`.
    nonisolated static func animationClockNow() -> Double {
        Date().timeIntervalSinceReferenceDate
    }

    nonisolated static func displayName(_ record: NodeRecord) -> String {
        record.short_name ?? record.long_name ?? record.hexid
            ?? String(format: "!%08x", UInt32(truncatingIfNeeded: record.node_num))
    }
}
