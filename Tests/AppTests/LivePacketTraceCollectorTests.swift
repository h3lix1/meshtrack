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
}
