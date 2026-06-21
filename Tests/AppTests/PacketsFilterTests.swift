@testable import App
import Domain
import Testing

@Suite("Packet filtering")
struct PacketsFilterTests {
    private func inspection(
        from: UInt32,
        port: MeshPort,
        channel: UInt32,
        payload: [UInt8] = [],
        sequence: Int
    ) -> InspectedPacket {
        InspectedPacket(
            packet: DecodedPacket(
                from: from, to: 0xFFFF_FFFF, packetID: UInt32(0x1000 + sequence),
                channel: channel, port: port, payload: payload, rxTime: .epoch,
                gatewayID: 0xFF
            ),
            ingestTime: nil,
            sequence: sequence
        )
    }

    private var sample: [InspectedPacket] {
        [
            inspection(from: 0xAA, port: .textMessage, channel: 0, payload: Array("hello world".utf8), sequence: 0),
            inspection(from: 0xBB, port: .telemetry, channel: 8, sequence: 1),
            inspection(from: 0xAA, port: .position, channel: 8, sequence: 2),
            inspection(from: 0xCC, port: .other(99), channel: 0, sequence: 3)
        ]
    }

    @Test
    func `empty filter matches everything`() {
        #expect(PacketFilter().apply(to: sample).count == 4)
        #expect(!PacketFilter().isActive)
    }

    @Test
    func `filter by port`() {
        let out = PacketFilter(port: .telemetry).apply(to: sample)
        #expect(out.map(\.sequence) == [1])
    }

    @Test
    func `filter by an unmodelled port matches by raw value`() {
        let out = PacketFilter(port: .other(99)).apply(to: sample)
        #expect(out.map(\.sequence) == [3])
    }

    @Test
    func `filter by source node`() {
        let out = PacketFilter(fromNode: 0xAA).apply(to: sample)
        #expect(out.map(\.sequence) == [0, 2])
    }

    @Test
    func `filter by channel`() {
        let out = PacketFilter(channel: 8).apply(to: sample)
        #expect(out.map(\.sequence) == [1, 2])
    }

    @Test
    func `text filter matches printable payload, case-insensitively`() {
        let out = PacketFilter(text: "WORLD").apply(to: sample)
        #expect(out.map(\.sequence) == [0])
    }

    @Test
    func `text filter matches hex node id`() {
        let out = PacketFilter(text: "000000bb").apply(to: sample)
        #expect(out.map(\.sequence) == [1])
    }

    @Test
    func `criteria combine with AND`() {
        let out = PacketFilter(fromNode: 0xAA, channel: 8).apply(to: sample)
        #expect(out.map(\.sequence) == [2])
    }

    @Test
    func `whitespace-only text is treated as inactive`() {
        let f = PacketFilter(text: "   ")
        #expect(!f.isActive)
        #expect(f.apply(to: sample).count == 4)
    }
}
