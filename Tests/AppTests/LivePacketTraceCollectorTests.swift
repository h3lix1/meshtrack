@testable import App
import Domain
import Testing

@Suite("LivePacketTraceCollector")
struct LivePacketTraceCollectorTests {
    private let positions: [Int64: GeoPoint] = [
        0x0000_0001: GeoPoint(latitude: 37.0, longitude: -122.0), // source
        0x0000_00FF: GeoPoint(latitude: 37.5, longitude: -122.0), // gateway A
        0x0000_00EE: GeoPoint(latitude: 37.3, longitude: -121.8) // gateway B
    ]

    private func packet(id: UInt32, gateway: UInt32, relay: UInt8 = 0) -> DecodedPacket {
        DecodedPacket(
            from: 0x0000_0001, to: 0xFFFF_FFFF, packetID: id, channel: 0,
            port: .telemetry, payload: [], rxTime: .epoch,
            hopStart: 3, hopLimit: 1, relayNode: relay, gatewayID: gateway
        )
    }

    @Test
    func `one decoded packet yields one trace`() {
        var collector = LivePacketTraceCollector()
        collector.ingest(packet(id: 0xAA, gateway: 0x0000_00FF))
        #expect(collector.packetCount == 1)
        #expect(collector.traces(positions: positions).count == 1)
    }

    @Test
    func `the same packet via two gateways stays one packet with two edges`() {
        var collector = LivePacketTraceCollector()
        collector.ingest(packet(id: 0xAA, gateway: 0x0000_00FF))
        collector.ingest(packet(id: 0xAA, gateway: 0x0000_00EE))
        #expect(collector.packetCount == 1)
        #expect(collector.traces(positions: positions).first?.edges.count == 2)
    }

    @Test
    func `the window evicts the oldest packets beyond the cap`() {
        var collector = LivePacketTraceCollector(maxPackets: 3)
        for id in UInt32(1) ... 6 {
            collector.ingest(packet(id: id, gateway: 0x0000_00FF))
        }
        #expect(collector.packetCount == 3)
        let ids = collector.traces(positions: positions).map(\.id).sorted()
        #expect(ids == [4, 5, 6]) // 1...3 evicted
    }

    @Test
    func `startedAt is staggered by arrival order`() {
        var collector = LivePacketTraceCollector()
        collector.ingest(packet(id: 0x01, gateway: 0x0000_00FF))
        collector.ingest(packet(id: 0x02, gateway: 0x0000_00FF))
        let traces = collector.traces(positions: positions, stagger: 0.5)
        #expect(traces.first { $0.id == 0x01 }?.startedAt == 0.0)
        #expect(traces.first { $0.id == 0x02 }?.startedAt == 0.5)
    }

    @Test
    func `arrivalClock anchors startedAt to the live animation clock`() {
        // Task 2: a packet stamped with a real clock value must use it as startedAt so
        // the overlay animates it from progress 0 (clock - startedAt ≈ 0), not saturated.
        var collector = LivePacketTraceCollector()
        collector.ingest(packet(id: 0x01, gateway: 0x0000_00FF), arrivalClock: 1000.0)
        let trace = collector.traces(positions: positions).first { $0.id == 0x01 }
        #expect(trace?.startedAt == 1000.0)
    }

    @Test
    func `a clockless packet beside clocked ones does not saturate hop progress`() {
        // Task 3: mixing regimes (a ~7.9e8 reference-date clock against a ~0.4 per-index
        // stagger) made the clocked packet's startedAt ≈ clock, so clock - startedAt was
        // huge and its hop lines drew instantly complete. When ANY packet lacks an
        // arrival clock the whole window must fall back uniformly to the small stagger,
        // so every packet's startedAt stays in the same regime as the overlay clock.
        let referenceClock = 790_000_000.0 // typical timeIntervalSinceReferenceDate
        var collector = LivePacketTraceCollector()
        collector.ingest(packet(id: 0x01, gateway: 0x0000_00FF), arrivalClock: referenceClock)
        collector.ingest(packet(id: 0x02, gateway: 0x0000_00EE)) // clockless neighbour

        let stagger = 0.4
        let traces = collector.traces(positions: positions, stagger: stagger)
        #expect(traces.count == 2)

        // All startedAt values must be in the small stagger regime, NOT anchored to the
        // huge reference clock.
        for trace in traces {
            #expect(trace.startedAt < referenceClock / 2)
            #expect(trace.startedAt <= Double(traces.count) * stagger)
        }

        // Replay the view's edgeProgress math with an overlay clock that has just begun
        // ticking (start of playback, ~0): no first edge should already be complete.
        let hopDuration = 1.2
        func edgeProgress(_ trace: PacketTrace, _ edgeIndex: Int, clock: Double) -> Double {
            let elapsed = clock - trace.startedAt - Double(edgeIndex) * hopDuration
            return min(1, max(0, elapsed / hopDuration))
        }
        for trace in traces {
            #expect(edgeProgress(trace, 0, clock: 0.0) < 1.0)
        }
    }

    @Test
    func `re-reception via another gateway keeps the original arrival clock`() {
        var collector = LivePacketTraceCollector()
        collector.ingest(packet(id: 0x01, gateway: 0x0000_00FF), arrivalClock: 500.0)
        collector.ingest(packet(id: 0x01, gateway: 0x0000_00EE), arrivalClock: 900.0)
        let trace = collector.traces(positions: positions).first { $0.id == 0x01 }
        #expect(trace?.startedAt == 500.0) // stamped on first sight only
        #expect(trace?.edges.count == 2)
    }
}
