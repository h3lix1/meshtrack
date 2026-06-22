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
    /// While a packet is selected it is *also* pinned in the window: its receptions
    /// are never evicted by the cap, so its aggregate detail stays intact and its
    /// row doesn't vanish while you inspect it (item 6). It ages out normally once
    /// deselected. Changing the selection re-runs eviction so a now-unpinned packet
    /// can drop and the newly-pinned one is protected.
    public var selectedID: UInt32? {
        didSet { evictOverflow() }
    }

    /// The live sliding-window cap (in receptions), configurable from the screen
    /// (item 7). Growing it lets more history accumulate; shrinking it evicts the
    /// oldest receptions immediately (still honouring the selection pin). Clamped to
    /// `>= 1`. Defaults to 200; `init(clock:maxPackets:)` seeds it. Backed by a private
    /// store so the setter never self-assigns — an `@Observable` `didSet` that rewrites
    /// its own property re-enters the observation machinery and overflows the stack.
    public var windowSize: Int {
        get { storedWindowSize }
        set {
            let clamped = max(1, newValue)
            guard clamped != storedWindowSize else { return }
            storedWindowSize = clamped
            evictOverflow()
        }
    }

    private var storedWindowSize: Int

    private let clock: Clock
    private var nextSequence = 0

    /// - Parameters:
    ///   - clock: source of the ingest wall-clock used to compute latency for live
    ///     packets. Production wires `SystemClock`; tests wire `InjectedClock`.
    ///   - maxPackets: initial sliding-window size (in receptions); oldest evicted
    ///     past this. Settable live afterwards via `windowSize`. The default reads the
    ///     user's persisted choice (item 7) so the live app restores it on launch
    ///     without a view-lifecycle hook — those crash the headless ImageRenderer. A
    ///     clean defaults domain (CI/tests) yields 200, so the literal default is
    ///     unchanged from the caller's perspective; explicit values bypass persistence.
    public init(clock: Clock, maxPackets: Int = PacketWindowPreference.restore()) {
        self.clock = clock
        storedWindowSize = max(1, maxPackets)
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
        evictOverflow()
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

    /// Trim the window back to `windowSize`, dropping the *oldest* receptions —
    /// except every reception of the currently-`selectedID` packet, which is pinned
    /// (item 6) so the inspected aggregate stays intact and its row never vanishes.
    /// Unpinned receptions are dropped oldest-first until the cap is met; if the
    /// pinned packet alone exceeds the cap, the window may stay larger than the cap
    /// (the pin wins), but that resolves the moment the packet is deselected/ages.
    private func evictOverflow() {
        guard packets.count > windowSize else { return }
        let pinnedID = selectedID
        var keptUnpinned = 0
        // packets is newest-first: walk newest→oldest, keep all pinned receptions
        // plus the first `windowSize` unpinned ones, drop the rest.
        packets = packets.filter { reception in
            if reception.packetID == pinnedID { return true }
            guard keptUnpinned < windowSize else { return false }
            keptUnpinned += 1
            return true
        }
    }

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
