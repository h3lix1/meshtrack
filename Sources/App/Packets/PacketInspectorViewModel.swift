// PacketInspectorViewModel — the composition seam for the packet inspector (G6).
// Holds a sliding window of recently decoded packets (fed via an `ingest` seam
// mirroring NetworkViewModel), each turned into a pure InspectedPacket with a
// byte-level breakdown + decoded field summary.
//
// The master list is aggregated by packet id (item 10): one row per id, grouping
// every reception (relay/gateway duplicate) of that packet, so the live list is no
// longer a flood of duplicates. The detail pane unfolds the full per-packet story.
// Filters (port/node/channel/text) act on the aggregated list. Per-reception
// latency is sanitised (item 9): receptions whose node RTC is skewed out of the
// plausible band are excluded from the distribution and the `latencyMillis` map.
//
// @MainActor @Observable; all the heavy lifting (breakdown, grouping, filtering,
// latency, distribution) is in pure helpers so this stays a thin coordinator.

import Domain
import Foundation
import Observation

@Observable
@MainActor
public final class PacketInspectorViewModel {
    /// The newest-first sliding window of inspected *receptions* (capped at
    /// `maxPackets`). One logical packet may appear several times here (relay
    /// duplicates) — the master list aggregates them by id.
    public private(set) var packets: [InspectedPacket] = []

    /// The active filter; setting it re-derives the selection if it falls out.
    public var filter = PacketFilter() {
        didSet { dropStaleSelection() }
    }

    /// The user's explicit master/detail pick (a packet id). Nil means "follow the
    /// newest visible packet" — the live default. Set it to pin the detail pane.
    public var selectedID: UInt32?

    private let clock: Clock
    private let maxPackets: Int
    private var nextSequence = 0

    /// - Parameters:
    ///   - clock: source of the ingest wall-clock used to compute latency for live
    ///     packets. Production wires `SystemClock`; tests wire `InjectedClock`.
    ///   - maxPackets: sliding-window size (in receptions); oldest evicted past this.
    public init(clock: Clock, maxPackets: Int = 200) {
        self.clock = clock
        self.maxPackets = max(1, maxPackets)
    }

    // MARK: Ingest seam

    /// Feed one decoded packet in. The ingest `Instant` is captured from the clock
    /// at arrival and paired with `rxTime` to give the receive→publish latency.
    public func ingest(_ packet: DecodedPacket) {
        ingest(packet, ingestTime: clock.now())
    }

    /// Ingest with an explicit ingest time (for replay / deterministic tests where
    /// the ingest moment differs from "now").
    public func ingest(_ packet: DecodedPacket, ingestTime: Instant?) {
        let inspection = InspectedPacket(
            packet: packet,
            ingestTime: ingestTime,
            sequence: nextSequence
        )
        nextSequence += 1
        packets.insert(inspection, at: 0) // newest first
        if packets.count > maxPackets {
            packets.removeLast(packets.count - maxPackets)
        }
        dropStaleSelection()
    }

    // MARK: Derived (master/detail + filters)

    /// Every reception grouped into one aggregate per packet id, newest id first.
    public var aggregatedPackets: [AggregatedPacket] {
        AggregatedPacket.group(packets)
    }

    /// The aggregated window after the active filter, newest first — the master list.
    public var visiblePackets: [AggregatedPacket] {
        filter.apply(to: aggregatedPackets)
    }

    /// The aggregate shown in the detail pane: the selection if still visible, else
    /// the newest visible aggregate.
    public var selected: AggregatedPacket? {
        let visible = visiblePackets
        if let selectedID, let hit = visible.first(where: { $0.packetID == selectedID }) {
            return hit
        }
        return visible.first
    }

    /// Distinct source nodes currently in the window (for the node filter menu).
    public var knownSources: [UInt32] {
        var seen = Set<UInt32>()
        return packets.compactMap { seen.insert($0.from).inserted ? $0.from : nil }
    }

    /// Distinct ports currently in the window (for the port filter menu).
    public var knownPorts: [MeshPort] {
        var seen = Set<Int>()
        return packets.compactMap {
            seen.insert($0.port.portNumRawValue).inserted ? $0.port : nil
        }
    }

    // MARK: Latency API

    /// Receive→publish latency in milliseconds per packet id — the public surface
    /// the map overlay (`MeshMapSection(latencyMillis:)`) and analytics consume.
    /// Skewed-RTC receptions are excluded (item 9): only *plausible* latencies are
    /// published. When a packet id has several plausible receptions, the most recent
    /// one wins (newest-first iteration, first write kept).
    public var latencyMillis: [UInt32: Int] {
        var result: [UInt32: Int] = [:]
        for inspection in packets { // newest first
            guard result[inspection.packetID] == nil else { continue }
            if let millis = inspection.plausibleLatencyMillis {
                result[inspection.packetID] = millis
            }
        }
        return result
    }

    /// The latency distribution over the *visible* (filtered) window — the small
    /// histogram + summary stats. Only plausible receptions contribute (item 9),
    /// so a node with a skewed clock no longer poisons the histogram.
    public var latencyDistribution: LatencyDistribution {
        let samples = visiblePackets
            .flatMap(\.receptions)
            .compactMap(\.plausibleLatencyMillis)
        return LatencyDistribution(millis: samples)
    }

    // MARK: Internals

    /// Clear an explicit selection that's no longer visible (filtered out or
    /// evicted from the window), so the detail pane falls back to the newest
    /// visible aggregate rather than going blank.
    private func dropStaleSelection() {
        guard let selectedID else { return }
        if !visiblePackets.contains(where: { $0.packetID == selectedID }) {
            self.selectedID = nil
        }
    }
}
