// NodeAnalyticsViewModel — the per-node analytics deep-dive (Phase 7 G4).
//
// Drives the five-tab dashboard for one node: SNR/RSSI distribution, hop-count
// histogram, peer/topology graph, hourly activity heatmap, and packet-type
// breakdown. The aggregations are the pure `NodeAnalytics.*` functions; this VM
// only sources their inputs and caches the results for the views.
//
// Input seams (mirrors `NetworkViewModel`):
//   * `observations` — provenance rows (rx_snr, rx_rssi, hop_start/limit,
//     gateway_id, rx_time). `load()` reads them from the store
//     (`observations(forNode:)`, Phase 10 item 7); the live coordinator (G2) can also
//     push them via `setObservations`/`ingest`; tests seed them directly. SNR/RSSI,
//     hops, peers and the heatmap derive from these.
//   * `packets` — decoded packets carrying the `MeshPort` the breakdown needs
//     (the observation table has no port column). Fed via `ingest`/`setPackets`.
//
// @MainActor @Observable; the recompute is synchronous over cached inputs and the
// derived outputs are unit-tested.

import Domain
import Foundation
import Observation
import Persistence

/// The analytics tabs, in display order.
public enum NodeAnalyticsTab: String, Sendable, CaseIterable, Identifiable {
    case signal
    case hops
    case peers
    case activity
    case packetTypes

    public var id: String {
        rawValue
    }

    public var label: String {
        switch self {
        case .signal: "Signal"
        case .hops: "Hops"
        case .peers: "Peers"
        case .activity: "Activity"
        case .packetTypes: "Packet Types"
        }
    }
}

@Observable
@MainActor
public final class NodeAnalyticsViewModel {
    public let nodeNum: Int64

    /// The currently selected tab.
    public var tab: NodeAnalyticsTab = .signal

    // Derived outputs (recomputed when inputs change).
    public private(set) var snr: SignalDistribution = .empty
    public private(set) var rssi: SignalDistribution = .empty
    public private(set) var hops: [HopBucket] = []
    public private(set) var peers: [PeerSummary] = []
    public private(set) var hourly: [HourBucket] = []
    public private(set) var packetTypes: [PacketTypeCount] = []

    public private(set) var observationCount = 0
    public private(set) var packetCount = 0

    @ObservationIgnored private let store: MeshStore
    @ObservationIgnored private var observations: [ObservationRecord] = []
    @ObservationIgnored private var packets: [DecodedPacket] = []
    /// Number of histogram bins for the signal-distribution tab.
    @ObservationIgnored private let binCount: Int

    public init(store: MeshStore, nodeNum: Int64, binCount: Int = 12) {
        self.store = store
        self.nodeNum = nodeNum
        self.binCount = binCount
    }

    /// Whether any analytics input has arrived.
    public var hasData: Bool {
        observationCount > 0 || packetCount > 0
    }

    /// The node's display name (best-effort; falls back to the hex id).
    public private(set) var nodeName: String?

    /// Load the node's display name from the store (the analytics header). The
    /// analytics inputs themselves are fed via the observation/packet seams.
    public func loadHeader() async throws {
        if let record = try await store.fetchNode(nodeNum: nodeNum) {
            nodeName = NetworkViewModel.displayName(record)
        }
    }

    /// Load the header AND the node's stored observations (Phase 10 item 7). The
    /// signal / hops / peers / activity tabs derive from these — previously they had
    /// no store-backed source and the section rendered empty regardless of node. The
    /// packet-type tab still needs the live packet feed (the observation table carries
    /// no port column), so it stays empty until packets arrive via `ingest`/`setPackets`.
    public func load() async throws {
        try await loadHeader()
        try await setObservations(store.observations(forNode: nodeNum))
    }

    // MARK: Input seams

    /// Replace the observation set (SNR/RSSI, hops, peers, heatmap) and recompute.
    public func setObservations(_ observations: [ObservationRecord]) {
        self.observations = observations
        recomputeObservationDerived()
    }

    /// Replace the decoded-packet set (packet-type breakdown) and recompute.
    public func setPackets(_ packets: [DecodedPacket]) {
        self.packets = packets
        recomputePacketDerived()
    }

    /// Append one observation (live feed) and recompute.
    public func ingest(observation: ObservationRecord) {
        observations.append(observation)
        recomputeObservationDerived()
    }

    /// Append one decoded packet (live feed) and recompute.
    public func ingest(packet: DecodedPacket) {
        packets.append(packet)
        recomputePacketDerived()
    }

    // MARK: Recompute

    private func recomputeObservationDerived() {
        observationCount = observations.count
        snr = NodeAnalytics.snrDistribution(observations: observations, binCount: binCount)
        rssi = NodeAnalytics.rssiDistribution(observations: observations, binCount: binCount)
        hops = NodeAnalytics.hopHistogram(observations: observations)
        peers = NodeAnalytics.peerSummaries(observations: observations)
        hourly = NodeAnalytics.hourlyActivity(observations: observations)
    }

    private func recomputePacketDerived() {
        packetCount = packets.count
        packetTypes = NodeAnalytics.packetTypeBreakdown(packets: packets)
    }
}
