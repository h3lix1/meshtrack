@testable import App
import Domain
import Testing

@Suite("Observability derivations")
struct ObservabilityDerivationTests {
    private static let second: Int64 = 1_000_000_000

    private func at(_ seconds: Int64) -> Instant {
        Instant(nanosecondsSinceEpoch: seconds * Self.second)
    }

    @Test
    func `lag is now minus last packet, clamped at zero`() {
        var health = IngestHealth(lastPacketAt: at(100))
        #expect(IngestHealthDerivation.lagSeconds(health, now: at(130)) == 30)

        // A clock slightly behind the last packet never reports negative lag.
        #expect(IngestHealthDerivation.lagSeconds(health, now: at(90)) == 0)

        // No packet yet → no lag.
        health.lastPacketAt = nil
        #expect(IngestHealthDerivation.lagSeconds(health, now: at(130)) == nil)
    }

    @Test
    func `average throughput is decoded over elapsed seconds`() {
        let health = IngestHealth(packetsDecoded: 600, startedAt: at(0))
        #expect(IngestHealthDerivation.averageThroughput(health, now: at(300)) == 2.0)

        // No elapsed time → nil (avoid divide-by-zero).
        #expect(IngestHealthDerivation.averageThroughput(health, now: at(0)) == nil)

        // No start → nil.
        let unstarted = IngestHealth(packetsDecoded: 600)
        #expect(IngestHealthDerivation.averageThroughput(unstarted, now: at(300)) == nil)
    }

    @Test
    func `decode error and success rates are complementary, zero-safe`() {
        let health = IngestHealth(framesProcessed: 1000, decodeErrors: 50)
        #expect(IngestHealthDerivation.decodeErrorRate(health) == 0.05)
        #expect(IngestHealthDerivation.decodeSuccessRate(health) == 0.95)

        // No frames processed → 0% error (not 100%), 100% success.
        let empty = IngestHealth()
        #expect(IngestHealthDerivation.decodeErrorRate(empty) == 0)
        #expect(IngestHealthDerivation.decodeSuccessRate(empty) == 1)
    }

    @Test
    func `dedup rate is duplicates over total deliveries`() {
        // 200 recorded + 800 duplicates = 1000 deliveries; 80% collapsed.
        let health = IngestHealth(observationsRecorded: 200, duplicateDeliveriesSkipped: 800)
        #expect(IngestHealthDerivation.dedupRate(health) == 0.8)

        // No deliveries → 0 (no divide-by-zero).
        #expect(IngestHealthDerivation.dedupRate(IngestHealth()) == 0)
    }

    @Test
    func `connected transport count tallies only connected`() {
        let health = IngestHealth(transports: [
            TransportHealth(transport: .mqtt, connected: true, framesReceived: 10),
            TransportHealth(transport: .serial, connected: false, framesReceived: 0),
            TransportHealth(transport: .ble, connected: true, framesReceived: 3)
        ])
        #expect(IngestHealthDerivation.connectedTransportCount(health) == 2)
    }

    @Test
    func `lag tile status escalates good then warn then bad`() {
        func lagStatus(secondsAgo: Int64) -> HealthMetric.Status? {
            let health = IngestHealth(lastPacketAt: at(0))
            let tiles = IngestHealthDerivation.metrics(health, now: at(secondsAgo))
            return tiles.first { $0.id == "lag" }?.status
        }
        #expect(lagStatus(secondsAgo: 10) == .good)
        #expect(lagStatus(secondsAgo: 120) == .warn)
        #expect(lagStatus(secondsAgo: 600) == .bad)
    }

    @Test
    func `lag tile is neutral with no data`() {
        let tiles = IngestHealthDerivation.metrics(IngestHealth(), now: at(100))
        let lag = tiles.first { $0.id == "lag" }
        #expect(lag?.status == .neutral)
        #expect(lag?.value == "—")
    }

    @Test
    func `transports tile reflects partial connectivity`() {
        let health = IngestHealth(transports: [
            TransportHealth(transport: .mqtt, connected: true, framesReceived: 10),
            TransportHealth(transport: .serial, connected: false, framesReceived: 0)
        ])
        let tile = IngestHealthDerivation.metrics(health, now: at(0)).first { $0.id == "transports" }
        #expect(tile?.value == "1/2")
        #expect(tile?.status == .warn)
    }

    @Test
    func `duration formatting buckets seconds minutes hours`() {
        #expect(IngestHealthDerivation.formatDuration(0.4) == "<1s")
        #expect(IngestHealthDerivation.formatDuration(45) == "45s")
        #expect(IngestHealthDerivation.formatDuration(120) == "2m")
        #expect(IngestHealthDerivation.formatDuration(7200) == "2.0h")
    }

    @Test
    @MainActor
    func `view model derives message count and lag from the pushed snapshot`() {
        let viewModel = ObservabilityViewModel()
        viewModel.update(
            IngestHealth(messagesRecorded: 9, lastPacketAt: at(100)),
            now: at(140)
        )
        #expect(viewModel.lagSeconds == 40)
        let messages = viewModel.metrics.first { $0.id == "messages" }
        #expect(messages?.value == "9")
    }

    @Test
    @MainActor
    func `view model defaults now to last packet when not supplied`() {
        let viewModel = ObservabilityViewModel()
        viewModel.update(IngestHealth(lastPacketAt: at(500)))
        // now defaulted to lastPacketAt → zero lag.
        #expect(viewModel.lagSeconds == 0)
    }
}
