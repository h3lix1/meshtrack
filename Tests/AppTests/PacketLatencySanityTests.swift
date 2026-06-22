@testable import App
import Domain
import Testing

@Suite("Latency sanitising in the inspector (item 9)")
@MainActor
struct PacketLatencySanityTests {
    private let baseRx = Instant(nanosecondsSinceEpoch: 1_000_000_000)

    private func packet(packetID: UInt32, rxSeconds: Double = 1.0) -> DecodedPacket {
        DecodedPacket(
            from: 0xAA, to: 0xFFFF_FFFF, packetID: packetID, channel: 0,
            port: .telemetry, payload: [],
            rxTime: Instant(nanosecondsSinceEpoch: 0).adding(seconds: rxSeconds),
            gatewayID: 0xFF
        )
    }

    private func inspect(packetID: UInt32, latencySeconds: Double) -> InspectedPacket {
        let packet = DecodedPacket(
            from: 0xAA, to: 0xFFFF_FFFF, packetID: packetID, channel: 0,
            port: .telemetry, payload: [], rxTime: baseRx, gatewayID: 0xFF
        )
        return InspectedPacket(
            packet: packet,
            ingestTime: baseRx.adding(seconds: latencySeconds),
            sequence: 0
        )
    }

    // MARK: InspectedPacket accessors

    @Test
    func `plausible latency is exposed; raw is preserved`() {
        let i = inspect(packetID: 1, latencySeconds: 0.2)
        #expect(i.latencyIsPlausible)
        #expect(i.plausibleLatencyMillis == 200)
        #expect(i.latencyMillis == 200) // raw still available for diagnostics
    }

    @Test
    func `a skewed-RTC reception is implausible and yields nil plausible millis`() {
        let i = inspect(packetID: 1, latencySeconds: 7 * 24 * 3600) // a week
        #expect(!i.latencyIsPlausible)
        #expect(i.plausibleLatencyMillis == nil)
        #expect(i.latencyMillis != nil) // raw garbage still computable, just not shown
    }

    // MARK: latencyMillis map (map-overlay surface) excludes skew

    @Test
    func `latencyMillis map excludes implausible receptions`() {
        let clock = InjectedClock(Instant(nanosecondsSinceEpoch: 0))
        let vm = PacketInspectorViewModel(clock: clock)
        // a node whose rx_time is a week behind → implausible
        let skewed = packet(packetID: 0xBAD, rxSeconds: 1.0)
        vm.ingest(skewed, ingestTime: skewed.rxTime.adding(seconds: 7 * 24 * 3600))
        // a healthy reception
        let good = packet(packetID: 0x600D, rxSeconds: 1.0)
        vm.ingest(good, ingestTime: good.rxTime.adding(seconds: 0.15))
        #expect(vm.latencyMillis[0xBAD] == nil) // skew kept out of the overlay
        #expect(vm.latencyMillis[0x600D] == 150)
    }

    @Test
    func `latency distribution excludes implausible receptions`() {
        let clock = InjectedClock(Instant(nanosecondsSinceEpoch: 0))
        let vm = PacketInspectorViewModel(clock: clock)
        for (id, ms) in [(UInt32(1), 0.1), (UInt32(2), 0.2)] as [(UInt32, Double)] {
            let pkt = packet(packetID: id, rxSeconds: 1.0)
            vm.ingest(pkt, ingestTime: pkt.rxTime.adding(seconds: ms))
        }
        // skewed reception of a third id
        let bad = packet(packetID: 3, rxSeconds: 1.0)
        vm.ingest(bad, ingestTime: bad.rxTime.adding(seconds: 7 * 24 * 3600))
        let dist = vm.latencyDistribution
        #expect(dist.sampleCount == 2) // skew excluded from stats
        #expect(dist.maxMillis == 200)
    }

    // MARK: latency journey

    @Test
    func `latency journey reports min median max spread over plausible receptions`() {
        let aggregate = AggregatedPacket(packetID: 9, receptions: [
            inspect(packetID: 9, latencySeconds: 0.3),
            inspect(packetID: 9, latencySeconds: 0.1),
            inspect(packetID: 9, latencySeconds: 0.2)
        ])
        let journey = aggregate.latencyJourney
        #expect(journey.minMillis == 100)
        #expect(journey.maxMillis == 300)
        #expect(journey.medianMillis == 200)
        #expect(journey.spreadMillis == 200)
        #expect(journey.excludedCount == 0)
    }

    @Test
    func `latency journey excludes and counts skewed receptions`() {
        let aggregate = AggregatedPacket(packetID: 9, receptions: [
            inspect(packetID: 9, latencySeconds: 0.2),
            inspect(packetID: 9, latencySeconds: 7 * 24 * 3600) // skewed
        ])
        let journey = aggregate.latencyJourney
        #expect(journey.plausibleMillis == [200])
        #expect(journey.excludedCount == 1)
        #expect(!journey.isEmpty)
    }

    @Test
    func `an all-skew aggregate has an empty journey`() {
        let aggregate = AggregatedPacket(packetID: 9, receptions: [
            inspect(packetID: 9, latencySeconds: 7 * 24 * 3600)
        ])
        let journey = aggregate.latencyJourney
        #expect(journey.isEmpty)
        #expect(journey.excludedCount == 1)
        #expect(journey.minMillis == nil)
    }
}
