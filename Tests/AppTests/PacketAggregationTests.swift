@testable import App
import Domain
import Testing

@Suite("Aggregating receptions by packet id (item 10)")
struct PacketAggregationTests {
    /// Build a reception of `packetID` with the given provenance + latency.
    private func reception(
        packetID: UInt32,
        from: UInt32 = 0xAA,
        port: MeshPort = .textMessage,
        channel: UInt32 = 0,
        hopStart: UInt8? = 3,
        hopLimit: UInt8? = 1,
        relay: UInt8? = 0x2A,
        gateway: UInt32? = 0xFF,
        snr: Double? = 5,
        rssi: Int? = -90,
        sequence: Int,
        latencySeconds: Double? = nil
    ) -> InspectedPacket {
        let rx = Instant(nanosecondsSinceEpoch: 1_000_000_000)
        let packet = DecodedPacket(
            from: from, to: 0xFFFF_FFFF, packetID: packetID, channel: channel,
            port: port, payload: Array("hello world".utf8), rxTime: rx,
            rxRssi: rssi, rxSnr: snr, hopStart: hopStart, hopLimit: hopLimit,
            relayNode: relay, gatewayID: gateway
        )
        return InspectedPacket(
            packet: packet,
            ingestTime: latencySeconds.map { rx.adding(seconds: $0) },
            sequence: sequence
        )
    }

    @Test
    func `group collapses receptions of one id into a single aggregate`() {
        let receptions = [
            reception(packetID: 0x77, gateway: 0xFF, sequence: 2),
            reception(packetID: 0x77, gateway: 0x42, sequence: 1),
            reception(packetID: 0x77, gateway: 0xA0, sequence: 0)
        ]
        let groups = AggregatedPacket.group(receptions)
        #expect(groups.count == 1)
        #expect(groups[0].packetID == 0x77)
        #expect(groups[0].receptionCount == 3)
        #expect(groups[0].distinctGatewayCount == 3)
    }

    @Test
    func `group preserves first-appearance order across distinct ids`() {
        let receptions = [
            reception(packetID: 3, sequence: 2),
            reception(packetID: 1, sequence: 1),
            reception(packetID: 3, sequence: 0)
        ]
        #expect(AggregatedPacket.group(receptions).map(\.packetID) == [3, 1])
    }

    @Test
    func `representative is the first (newest) reception`() {
        let aggregate = AggregatedPacket(packetID: 1, receptions: [
            reception(packetID: 1, gateway: 0xFF, sequence: 5),
            reception(packetID: 1, gateway: 0x42, sequence: 4)
        ])
        #expect(aggregate.representative.packet.gatewayID == 0xFF)
    }

    @Test
    func `hop range reflects differing hop counts`() {
        let aggregate = AggregatedPacket(packetID: 1, receptions: [
            reception(packetID: 1, hopStart: 3, hopLimit: 1, sequence: 1), // 2 hops
            reception(packetID: 1, hopStart: 3, hopLimit: 3, sequence: 0) // 0 hops
        ])
        #expect(aggregate.hopRangeText == "0–2")
    }

    @Test
    func `a single hop count renders without a range`() {
        let aggregate = AggregatedPacket(packetID: 1, receptions: [
            reception(packetID: 1, hopStart: 3, hopLimit: 1, sequence: 0)
        ])
        #expect(aggregate.hopRangeText == "2")
    }

    @Test
    func `filters apply to the aggregated list`() {
        let aggregates = AggregatedPacket.group([
            reception(packetID: 1, from: 0xAA, port: .textMessage, sequence: 2),
            reception(packetID: 2, from: 0xBB, port: .telemetry, sequence: 1),
            reception(packetID: 1, from: 0xAA, port: .textMessage, sequence: 0)
        ])
        #expect(PacketFilter(port: .telemetry).apply(to: aggregates).map(\.packetID) == [2])
        #expect(PacketFilter(fromNode: 0xAA).apply(to: aggregates).map(\.packetID) == [1])
    }

    @Test
    func `text filter matches a field carried only by a relay reception`() {
        // text appears in the haystack of the second reception only; the aggregate
        // should still match because any reception hitting is enough.
        let aggregates = AggregatedPacket.group([
            reception(packetID: 1, gateway: 0xFF, sequence: 1),
            reception(packetID: 1, gateway: 0x0000_0042, sequence: 0)
        ])
        #expect(PacketFilter(text: "00000042").apply(to: aggregates).count == 1)
    }

    @Test
    func `distinct paths count relay-gateway combinations`() {
        let aggregate = AggregatedPacket(packetID: 1, receptions: [
            reception(packetID: 1, relay: 0x2A, gateway: 0xFF, sequence: 2),
            reception(packetID: 1, relay: 0x2A, gateway: 0xFF, sequence: 1), // same path
            reception(packetID: 1, relay: 0x7C, gateway: 0x42, sequence: 0) // new path
        ])
        let paths = aggregate.paths
        #expect(aggregate.distinctPathCount == 2)
        // busiest path (×2) sorts first
        #expect(paths.first?.count == 2)
        #expect(paths.first?.relayByte == 0x2A)
    }
}
