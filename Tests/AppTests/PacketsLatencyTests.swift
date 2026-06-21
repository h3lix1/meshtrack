@testable import App
import Domain
import Testing

@Suite("Latency distribution + VM latency API")
@MainActor
struct PacketsLatencyTests {
    private func packet(
        packetID: UInt32,
        from: UInt32 = 0xAA,
        rxSeconds: Double,
        port: MeshPort = .telemetry
    ) -> DecodedPacket {
        DecodedPacket(
            from: from, to: 0xFFFF_FFFF, packetID: packetID, channel: 0, port: port,
            payload: [], rxTime: Instant(nanosecondsSinceEpoch: 0).adding(seconds: rxSeconds),
            gatewayID: 0xFF
        )
    }

    // MARK: Distribution

    @Test
    func `empty distribution`() {
        let d = LatencyDistribution(millis: [])
        #expect(d.isEmpty)
        #expect(d.buckets.isEmpty)
    }

    @Test
    func `distribution summary statistics`() {
        let d = LatencyDistribution(millis: [10, 20, 30, 40, 100])
        #expect(d.sampleCount == 5)
        #expect(d.minMillis == 10)
        #expect(d.maxMillis == 100)
        #expect(d.meanMillis == 40) // (200)/5
        #expect(d.medianMillis == 30)
        #expect(d.p95Millis == 100)
    }

    @Test
    func `negative skew samples are clamped to zero`() {
        let d = LatencyDistribution(millis: [-50, 0, 50])
        #expect(d.minMillis == 0)
        #expect(d.sampleCount == 3)
    }

    @Test
    func `histogram buckets account for every sample`() {
        let d = LatencyDistribution(millis: [0, 10, 20, 30, 40, 50, 60], bucketCount: 3)
        #expect(d.buckets.reduce(0) { $0 + $1.count } == 7)
        // the max value lands inside the final (inclusive) bucket
        #expect(d.buckets.last?.count ?? 0 >= 1)
    }

    // MARK: VM latency API

    @Test
    func `latencyMillis maps packet id to receive-to-publish ms`() {
        let clock = InjectedClock(Instant(nanosecondsSinceEpoch: 0))
        let vm = PacketInspectorViewModel(clock: clock)
        // rx at t=1.0s; ingest captured at clock = 1.2s → 200ms latency.
        clock.set(Instant(nanosecondsSinceEpoch: 0).adding(seconds: 1.2))
        vm.ingest(packet(packetID: 0xABCD, rxSeconds: 1.0))
        #expect(vm.latencyMillis[0xABCD] == 200)
    }

    @Test
    func `latencyMillis keeps the most recent reception of a duplicated id`() {
        let clock = InjectedClock(Instant(nanosecondsSinceEpoch: 0))
        let vm = PacketInspectorViewModel(clock: clock)
        // first reception: 100ms latency
        clock.set(Instant(nanosecondsSinceEpoch: 0).adding(seconds: 1.1))
        vm.ingest(packet(packetID: 0x55, rxSeconds: 1.0))
        // duplicate (relay) of the same id, newer, 300ms latency
        clock.set(Instant(nanosecondsSinceEpoch: 0).adding(seconds: 2.3))
        vm.ingest(packet(packetID: 0x55, rxSeconds: 2.0))
        #expect(vm.latencyMillis[0x55] == 300) // newest wins
    }

    @Test
    func `latencyMillis omits packets with no ingest time`() {
        let clock = InjectedClock()
        let vm = PacketInspectorViewModel(clock: clock)
        vm.ingest(packet(packetID: 0x99, rxSeconds: 0), ingestTime: nil)
        #expect(vm.latencyMillis[0x99] == nil)
    }

    @Test
    func `latencyDistribution covers the visible window`() {
        let clock = InjectedClock(Instant(nanosecondsSinceEpoch: 0))
        let vm = PacketInspectorViewModel(clock: clock)
        for (i, ms) in [100, 200, 300].enumerated() {
            clock.set(Instant(nanosecondsSinceEpoch: 0).adding(seconds: 1.0 + Double(ms) / 1000))
            vm.ingest(packet(packetID: UInt32(i), rxSeconds: 1.0))
        }
        let d = vm.latencyDistribution
        #expect(d.sampleCount == 3)
        #expect(d.minMillis == 100)
        #expect(d.maxMillis == 300)
    }
}
