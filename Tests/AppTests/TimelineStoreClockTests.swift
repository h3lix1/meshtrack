// TimelineStoreClockTests — the VCR replay corpus must order/window packets by OUR
// own ingest clock, not the node's claimed (firmware) rx_time. Too many nodes report a
// skewed RTC, which scattered packets to the wrong moments on the scrubber ("very odd
// results"). The store reads `COALESCE(ingest_time, rx_time)` so present ingest times
// win and pre-`ingest_time` rows still fall back to rx_time.

@testable import App
import Domain
import Persistence
import Testing

@Suite("TimelineStore clock source (ingest_time over firmware rx_time)")
struct TimelineStoreClockTests {
    private static let now = Instant(nanosecondsSinceEpoch: 1_700_000_000_000_000_000)

    private func store() async throws -> MeshStore {
        try MeshStore(DatabaseConnection.inMemory())
    }

    @Test
    func `windowing and replay time key off ingest_time, not the skewed firmware rx_time`() async throws {
        let store = try await store()
        // A node with a badly skewed RTC: it claims rx_time a year in the past, but we
        // actually received the frame 5 minutes ago — comfortably inside the window.
        let skewedRx = Self.now.adding(seconds: -365 * 24 * 3600)
        let ingest = Self.now.adding(seconds: -300)
        try await store.recordObservation(ObservationRecord(
            node_num: 7,
            packet_id: 42,
            transport: .mqtt,
            gateway_id: "!000000ff",
            rx_time: skewedRx.nanosecondsSinceEpoch,
            hop_start: 3,
            hop_limit: 1,
            ingest_time: ingest.nanosecondsSinceEpoch
        ))

        let window = try await store.timelineObservations(
            since: Self.now.adding(seconds: -3600),
            until: Self.now
        )

        // The firmware rx_time falls a year before the window, yet the row is included
        // because our ingest_time lands inside it …
        let observation = try #require(window.first)
        // … and the replay clock it carries is our ingest_time, not the firmware rx_time.
        #expect(observation.rxTime == ingest)
        #expect(observation.rxTime != skewedRx)
    }

    @Test
    func `rows without an ingest_time fall back to rx_time`() async throws {
        let store = try await store()
        let rx = Self.now.adding(seconds: -120)
        try await store.recordObservation(ObservationRecord(
            node_num: 7,
            packet_id: 43,
            transport: .mqtt,
            gateway_id: "!000000ff",
            rx_time: rx.nanosecondsSinceEpoch,
            hop_start: 3,
            hop_limit: 1
            // ingest_time omitted (pre-v3 row)
        ))

        let window = try await store.timelineObservations(
            since: Self.now.adding(seconds: -3600),
            until: Self.now
        )
        #expect(window.first?.rxTime == rx)
    }
}
