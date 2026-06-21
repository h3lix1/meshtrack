@testable import App
import Domain
import Testing

@Suite("Packet byte-breakdown + field summary")
struct PacketsInspectionTests {
    private func packet(
        from: UInt32 = 0x1111_1111,
        to: UInt32 = 0xFFFF_FFFF,
        packetID: UInt32 = 0xABCD,
        channel: UInt32 = 8,
        port: MeshPort = .telemetry,
        payload: [UInt8] = [],
        rxTime: Instant = .epoch,
        hopStart: UInt8? = 3,
        hopLimit: UInt8? = 1,
        relayNode: UInt8? = 0x2A,
        gatewayID: UInt32? = 0x0000_00FF,
        wasEncrypted: Bool = true
    ) -> DecodedPacket {
        DecodedPacket(
            from: from, to: to, packetID: packetID, channel: channel, port: port,
            payload: payload, rxTime: rxTime, hopStart: hopStart, hopLimit: hopLimit,
            relayNode: relayNode, gatewayID: gatewayID, wasEncrypted: wasEncrypted
        )
    }

    private func inspect(_ p: DecodedPacket, ingestTime: Instant? = nil) -> InspectedPacket {
        InspectedPacket(packet: p, ingestTime: ingestTime, sequence: 0)
    }

    @Test
    func `decoded field summary`() {
        let i = inspect(packet())
        #expect(i.portName == "TELEMETRY")
        #expect(i.hops == 2) // 3 - 1
        #expect(i.fromHex == "!11111111")
        #expect(i.toHex == "!ffffffff")
        #expect(i.relayByteText == "0x2a")
        #expect(i.gatewayText == "!000000ff")
        #expect(i.wasEncrypted)
    }

    @Test
    func `hops is nil when hop fields are absent`() {
        #expect(inspect(packet(hopStart: nil, hopLimit: nil)).hops == nil)
    }

    @Test
    func `hops clamps to zero rather than going negative`() {
        #expect(inspect(packet(hopStart: 1, hopLimit: 3)).hops == 0)
    }

    @Test
    func `unmodelled port keeps its raw number`() {
        let i = inspect(packet(port: .other(42)))
        #expect(i.portName == "PORT_42")
        #expect(i.port.portNumRawValue == 42)
    }

    @Test
    func `hex dump splits payload into 16-byte rows with ascii gutter`() {
        // 18 bytes → two rows (16 + 2). Includes printable + non-printable.
        let bytes: [UInt8] = Array(0x41...0x52) // "ABCDEFGHIJKLMNOPQR" (18 chars)
        let rows = inspect(packet(payload: bytes)).hexDump()
        #expect(rows.count == 2)
        #expect(rows[0].offset == 0)
        #expect(rows[0].bytes.count == 16)
        #expect(rows[0].offsetText == "0000")
        #expect(rows[0].asciiText == "ABCDEFGHIJKLMNOP")
        #expect(rows[1].offset == 16)
        #expect(rows[1].bytes == [0x51, 0x52])
        #expect(rows[1].offsetText == "0010")
        #expect(rows[1].asciiText == "QR")
        // short final row is padded to a full 16-cell width so the ascii gutter
        // stays aligned with the rows above it.
        #expect(rows[1].hexText.hasPrefix("51 52"))
        #expect(rows[1].hexText.count == rows[0].hexText.count)
        #expect(rows[0].hexText.count == 16 * 2 + 15) // 16 two-char cells + 15 gaps
    }

    @Test
    func `non-printable bytes render as dots in the ascii gutter`() {
        let rows = inspect(packet(payload: [0x00, 0x41, 0xFF, 0x42])).hexDump()
        #expect(rows[0].asciiText == ".A.B")
        #expect(rows[0].hexText.hasPrefix("00 41 ff 42"))
    }

    @Test
    func `empty payload yields no hex rows`() {
        #expect(inspect(packet(payload: [])).hexDump().isEmpty)
    }

    @Test
    func `latency is computed from rx and ingest times`() {
        let rx = Instant(nanosecondsSinceEpoch: 1_000_000_000)
        let ingest = rx.adding(seconds: 0.25) // 250ms later
        let i = inspect(packet(rxTime: rx), ingestTime: ingest)
        #expect(i.latencyMillis == 250)
        #expect(i.latency?.nanoseconds == 250_000_000)
    }

    @Test
    func `latency is nil when ingest time is unknown`() {
        #expect(inspect(packet(), ingestTime: nil).latencyMillis == nil)
    }

    @Test
    func `negative latency reflects clock skew`() {
        let rx = Instant(nanosecondsSinceEpoch: 2_000_000_000)
        let ingest = rx.adding(seconds: -0.1)
        #expect(inspect(packet(rxTime: rx), ingestTime: ingest).latencyMillis == -100)
    }
}
