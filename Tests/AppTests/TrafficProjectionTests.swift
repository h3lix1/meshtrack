@testable import App
import Domain
import Testing

@Suite("TrafficProjection — sorting, ranking, derivations")
struct TrafficProjectionTests {
    private func packet(
        from: UInt32,
        packetID: UInt32,
        port: MeshPort,
        gatewayID: UInt32? = 0xAA,
        at seconds: Double = 0,
        hopStart: UInt8? = 2,
        hopLimit: UInt8? = 1
    ) -> DecodedPacket {
        DecodedPacket(
            from: from, to: 0xFFFF_FFFF, packetID: packetID, channel: 8, port: port,
            payload: [], rxTime: Instant.epoch.adding(seconds: seconds),
            hopStart: hopStart, hopLimit: hopLimit, gatewayID: gatewayID
        )
    }

    private func aggregator(_ packets: [DecodedPacket]) -> TrafficAggregator {
        var agg = TrafficAggregator()
        for packet in packets {
            agg.fold(packet)
        }
        return agg
    }

    @Test
    func `port rows are sorted by receptions descending with the catalogue applied`() {
        let agg = aggregator([
            packet(from: 1, packetID: 1, port: .telemetry),
            packet(from: 1, packetID: 1, port: .telemetry, gatewayID: 0xBB),
            packet(from: 2, packetID: 2, port: .position)
        ])
        let rows = TrafficProjection.portRows(agg)
        #expect(rows.map(\.descriptor.rawValue) == [67, 3]) // telemetry (2 recv) before position (1)
        #expect(rows.first?.descriptor.name == "TELEMETRY_APP")
        #expect(rows.first?.receptions == 2)
    }

    @Test
    func `traffic share sums to one across ports`() {
        let agg = aggregator([
            packet(from: 1, packetID: 1, port: .telemetry),
            packet(from: 2, packetID: 2, port: .position),
            packet(from: 3, packetID: 3, port: .nodeInfo)
        ])
        let total = TrafficProjection.portRows(agg).map(\.trafficShare).reduce(0, +)
        #expect(abs(total - 1.0) < 0.0001)
    }

    @Test
    func `unmodelled raw port falls back to a generated descriptor`() {
        let agg = aggregator([packet(from: 1, packetID: 1, port: .other(200))])
        let row = TrafficProjection.portRows(agg).first
        #expect(row?.descriptor.rawValue == 200)
        #expect(row?.descriptor.name == "PORT_200")
    }

    @Test
    func `offenders rank by receptions then emitted then spread`() {
        // Node 1: 3 receptions of 1 packet. Node 2: 2 receptions of 2 packets.
        let agg = aggregator([
            packet(from: 1, packetID: 10, port: .position, gatewayID: 0xAA),
            packet(from: 1, packetID: 10, port: .position, gatewayID: 0xBB),
            packet(from: 1, packetID: 10, port: .position, gatewayID: 0xCC),
            packet(from: 2, packetID: 20, port: .telemetry, gatewayID: 0xAA),
            packet(from: 2, packetID: 21, port: .telemetry, gatewayID: 0xAA)
        ])
        let rows = TrafficProjection.offenderRows(agg)
        #expect(rows.map(\.nodeNum) == [1, 2]) // node 1 has more receptions
        #expect(rows.first?.receptions == 3)
        #expect(rows.first?.spread == 3)
    }

    @Test
    func `offender limit caps the worst-N`() {
        let agg = aggregator((0 ..< 5)
            .map { packet(from: UInt32($0), packetID: UInt32($0), port: .position) })
        #expect(TrafficProjection.offenderRows(agg, limit: 3).count == 3)
    }

    @Test
    func `dominant port is the node's most-received port`() {
        let agg = aggregator([
            packet(from: 1, packetID: 1, port: .position),
            packet(from: 1, packetID: 2, port: .position),
            packet(from: 1, packetID: 3, port: .telemetry)
        ])
        #expect(TrafficProjection.offenderRows(agg).first?.dominantPort?.rawValue == 3)
    }

    @Test
    func `packets per minute uses the observed window`() {
        // Two receptions 60s apart → 2 packets / 1 minute = 2.0.
        let agg = aggregator([
            packet(from: 1, packetID: 1, port: .position, at: 0),
            packet(from: 1, packetID: 2, port: .position, at: 60)
        ])
        let rate = TrafficProjection.offenderRows(agg).first?.packetsPerMinute ?? 0
        #expect(abs(rate - 2.0) < 0.0001)
    }

    @Test
    func `packets per minute falls back to count for a degenerate window`() {
        let agg = aggregator([packet(from: 1, packetID: 1, port: .position, at: 0)])
        #expect(TrafficProjection.offenderRows(agg).first?.packetsPerMinute == 1)
    }

    @Test
    func `channel and hop rows are ordered for display`() {
        let agg = aggregator([
            packet(from: 1, packetID: 1, port: .position, hopStart: 4, hopLimit: 1), // 3 hops
            packet(from: 2, packetID: 2, port: .position, hopStart: 2, hopLimit: 1), // 1 hop
            packet(from: 3, packetID: 3, port: .position, hopStart: 2, hopLimit: 1) // 1 hop
        ])
        #expect(TrafficProjection.channelRows(agg).first?.channel == 8)
        #expect(TrafficProjection.hopRows(agg).map(\.hops) == [1, 3]) // ascending
        #expect(TrafficProjection.hopRows(agg).first?.receptions == 2) // two 1-hop packets
    }
}
