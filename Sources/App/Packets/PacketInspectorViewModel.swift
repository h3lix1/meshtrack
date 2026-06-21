// PacketInspectorViewModel — the composition seam for the packet inspector (G6).
// Holds a sliding window of recently decoded packets (fed via an `ingest` seam
// mirroring NetworkViewModel), each turned into a pure InspectedPacket with a
// byte-level breakdown + decoded field summary. Surfaces filters (port/node/
// channel/text), master/detail selection, per-packet receive→publish latency, and
// a latency distribution.
//
// @MainActor @Observable; all the heavy lifting (breakdown, filtering, latency,
// distribution) is in pure helpers so this stays a thin, testable coordinator.

import Domain
import Foundation
import Observation

@Observable
@MainActor
public final class PacketInspectorViewModel {
    /// The newest-first sliding window of inspected packets (capped at `maxPackets`).
    public private(set) var packets: [InspectedPacket] = []

    /// The active filter; setting it re-derives the selection if it falls out.
    public var filter = PacketFilter() {
        didSet { dropStaleSelection() }
    }

    /// The user's explicit master/detail pick (`sequence`). Nil means "follow the
    /// newest visible packet" — the live default. Set it to pin the detail pane.
    public var selectedID: InspectedPacket.ID?

    private let clock: Clock
    private let maxPackets: Int
    private var nextSequence = 0

    /// - Parameters:
    ///   - clock: source of the ingest wall-clock used to compute latency for live
    ///     packets. Production wires `SystemClock`; tests wire `InjectedClock`.
    ///   - maxPackets: sliding-window size; oldest evicted past this.
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

    /// The window after the active filter, newest first — the master list.
    public var visiblePackets: [InspectedPacket] {
        filter.apply(to: packets)
    }

    /// The packet shown in the detail pane: the selection if still visible, else
    /// the newest visible packet.
    public var selected: InspectedPacket? {
        let visible = visiblePackets
        if let selectedID, let hit = visible.first(where: { $0.id == selectedID }) {
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
    /// When a packet id has several receptions in the window, the most recent one
    /// wins (newest-first iteration, first write kept).
    public var latencyMillis: [UInt32: Int] {
        var result: [UInt32: Int] = [:]
        for inspection in packets { // newest first
            guard result[inspection.packetID] == nil else { continue }
            if let ms = inspection.latencyMillis { result[inspection.packetID] = ms }
        }
        return result
    }

    /// The latency distribution over the *visible* (filtered) window — the small
    /// histogram + summary stats shown in the detail/analytics area.
    public var latencyDistribution: LatencyDistribution {
        LatencyDistribution(millis: visiblePackets.compactMap(\.latencyMillis))
    }

    // MARK: Internals

    /// Clear an explicit selection that's no longer visible (filtered out or
    /// evicted from the window), so the detail pane falls back to the newest
    /// visible packet rather than going blank.
    private func dropStaleSelection() {
        guard let selectedID else { return }
        if !visiblePackets.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }
}
