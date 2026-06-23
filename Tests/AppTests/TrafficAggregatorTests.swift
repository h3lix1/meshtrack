@testable import App
import Domain
import Testing

@Suite("TrafficAggregator — counting policy (receptions vs distinct)")
struct TrafficAggregatorTests {
    private func packet(
        from: UInt32 = 0xA1,
        packetID: UInt32 = 1,
        port: MeshPort = .position,
        channel: UInt32 = 8,
        hopStart: UInt8? = 3,
        hopLimit: UInt8? = 1,
        gatewayID: UInt32? = 0xAA,
        at seconds: Double = 0
    ) -> DecodedPacket {
        DecodedPacket(
            from: from, to: 0xFFFF_FFFF, packetID: packetID, channel: channel, port: port,
            payload: [], rxTime: Instant.epoch.adding(seconds: seconds),
            hopStart: hopStart, hopLimit: hopLimit, gatewayID: gatewayID
        )
    }

    @Test
    func `receptions count every fold but distinct packets dedupe identity`() {
        var aggregator = TrafficAggregator()
        // Same (from, packetID) heard by three gateways = one logical packet.
        aggregator.fold(packet(gatewayID: 0xAA))
        aggregator.fold(packet(gatewayID: 0xBB))
        aggregator.fold(packet(gatewayID: 0xCC))
        #expect(aggregator.totalReceptions == 3)
        #expect(aggregator.totalDistinctPackets == 1)
        let port = aggregator.ports[3]
        #expect(port?.receptions == 3)
        #expect(port?.distinctPackets == 1)
        #expect(port?.gateways.count == 3)
        #expect(port?.sourceNodes.count == 1)
    }

    @Test
    func `distinct identity is per (from, packetID) not per packetID alone`() {
        var aggregator = TrafficAggregator()
        aggregator.fold(packet(from: 0xA1, packetID: 7))
        aggregator.fold(packet(from: 0xB2, packetID: 7)) // same id, different node
        #expect(aggregator.totalDistinctPackets == 2)
    }

    @Test
    func `max hops tracks the largest hopStart minus hopLimit on a port`() {
        var aggregator = TrafficAggregator()
        aggregator.fold(packet(hopStart: 3, hopLimit: 1)) // 2 hops
        aggregator.fold(packet(packetID: 2, hopStart: 7, hopLimit: 0)) // 7 hops
        aggregator.fold(packet(packetID: 3, hopStart: 2, hopLimit: 2)) // 0 hops
        #expect(aggregator.ports[3]?.maxHops == 7)
    }

    @Test
    func `missing hop fields count as zero hops`() {
        var aggregator = TrafficAggregator()
        aggregator.fold(packet(hopStart: nil, hopLimit: nil))
        #expect(aggregator.ports[3]?.maxHops == 0)
        #expect(aggregator.hopHistogram[0] == 1)
    }

    @Test
    func `relay byte is the location fallback when no gateway is present`() {
        var aggregator = TrafficAggregator()
        let viaRelay = DecodedPacket(
            from: 0xA1, to: 0xFFFF_FFFF, packetID: 1, channel: 8, port: .position,
            payload: [], rxTime: .epoch, hopStart: 2, hopLimit: 1, relayNode: 0x42, gatewayID: nil
        )
        aggregator.fold(viaRelay)
        #expect(aggregator.ports[3]?.gateways == [0x42])
    }

    @Test
    func `node counters accumulate emitted, receptions, spread and a port tally`() {
        var aggregator = TrafficAggregator()
        aggregator.fold(packet(from: 0xA1, packetID: 1, port: .position, gatewayID: 0xAA))
        aggregator.fold(packet(from: 0xA1, packetID: 1, port: .position, gatewayID: 0xBB)) // dup
        aggregator.fold(packet(from: 0xA1, packetID: 2, port: .telemetry, gatewayID: 0xAA))
        let node = aggregator.nodes[0xA1]
        #expect(node?.emitted == 2) // two distinct packets
        #expect(node?.receptions == 3) // three receptions
        #expect(node?.gateways.count == 2) // heard by AA + BB
        #expect(node?.portReceptions[3] == 2)
        #expect(node?.portReceptions[67] == 1)
    }

    @Test
    func `channel and hop histograms tally every reception`() {
        var aggregator = TrafficAggregator()
        aggregator.fold(packet(channel: 8, hopStart: 3, hopLimit: 1))
        aggregator.fold(packet(packetID: 2, channel: 8, hopStart: 3, hopLimit: 1))
        aggregator.fold(packet(packetID: 3, channel: 31, hopStart: 4, hopLimit: 1))
        #expect(aggregator.channelReceptions[8] == 2)
        #expect(aggregator.channelReceptions[31] == 1)
        #expect(aggregator.hopHistogram[2] == 2)
        #expect(aggregator.hopHistogram[3] == 1)
    }
}
