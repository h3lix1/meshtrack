import Domain
import Foundation
@testable import Ingest
import MeshProtos
import Testing

@Suite("PacketDecoder")
struct PacketDecoderTests {
    // MARK: Fakes (no dependency on the Crypto module)

    private struct FakeKeyStore: KeyStore {
        var keysByChannel: [UInt32: ChannelKey] = [:]
        func key(forChannelHash channelHash: UInt32) -> ChannelKey? {
            keysByChannel[channelHash]
        }
    }

    /// Maps any ciphertext to a fixed plaintext (the inner DataMessage bytes).
    private struct FixedDecryptor: PacketDecryptor {
        let plaintext: [UInt8]
        func decrypt(_: [UInt8], packetID _: UInt32, fromNode _: UInt32, key _: ChannelKey) -> [UInt8] {
            plaintext
        }
    }

    private func dataMessage(port: PortNum, payload: [UInt8]) -> DataMessage {
        var data = DataMessage()
        data.portnum = port
        data.payload = Data(payload)
        return data
    }

    private func envelope(_ build: (inout MeshPacket) -> Void) throws -> [UInt8] {
        var packet = MeshPacket()
        packet.from = 0xA1B2_C3D4
        packet.to = 0xFFFF_FFFF
        packet.id = 0x0000_2A2A
        packet.channel = 8
        packet.rxSnr = 5.5
        packet.rxRssi = -90
        packet.hopStart = 3
        packet.hopLimit = 2
        build(&packet)
        var env = ServiceEnvelope()
        env.packet = packet
        env.channelID = "MediumFast"
        env.gatewayID = "!a1b2c3d4"
        return try [UInt8](env.serializedData())
    }

    // MARK: Tests

    @Test
    func `decodes a plaintext (decoded) packet with provenance`() throws {
        let bytes = try envelope { packet in
            packet.decoded = dataMessage(port: .telemetryApp, payload: [0x01, 0x02, 0x03])
        }
        let decoder = PacketDecoder(keyStore: FakeKeyStore(), decryptor: FixedDecryptor(plaintext: []))
        let packet = try #require(try decoder.decode(serviceEnvelope: bytes, receivedAt: at(10)))

        #expect(packet.from == 0xA1B2_C3D4)
        #expect(packet.packetID == 0x0000_2A2A)
        #expect(packet.channel == 8)
        #expect(packet.port == .telemetry)
        #expect(packet.payload == [0x01, 0x02, 0x03])
        #expect(packet.rxSnr == 5.5)
        #expect(packet.rxRssi == -90)
        #expect(packet.hopStart == 3)
        #expect(packet.hopLimit == 2)
        #expect(!packet.wasEncrypted)
        #expect(packet.rxTime == at(10))
        #expect(packet.dedupKey == DedupKey(packetID: 0x0000_2A2A, fromNode: 0xA1B2_C3D4))
    }

    @Test
    func `rxTime uses our receipt clock, keeping the node's claimed time separate`() throws {
        // Firmware stamps its own RTC (100s); we received the frame later, at 105s.
        let bytes = try envelope { packet in
            packet.decoded = dataMessage(port: .telemetryApp, payload: [0x01])
            packet.rxTime = 100
        }
        let decoder = PacketDecoder(keyStore: FakeKeyStore(), decryptor: FixedDecryptor(plaintext: []))
        let packet = try #require(try decoder.decode(serviceEnvelope: bytes, receivedAt: at(105)))
        // The canonical packet time ignores the (often-skewed) firmware clock …
        #expect(packet.rxTime == at(105))
        // … while the node's claimed time is preserved for descriptive latency only.
        #expect(packet.nodeRxTime == at(100))
    }

    @Test
    func `nodeRxTime is nil when the firmware omits its receive time`() throws {
        let bytes = try envelope { packet in
            packet.decoded = dataMessage(port: .telemetryApp, payload: [0x01])
            // packet.rxTime left at 0 (omitted)
        }
        let decoder = PacketDecoder(keyStore: FakeKeyStore(), decryptor: FixedDecryptor(plaintext: []))
        let packet = try #require(try decoder.decode(serviceEnvelope: bytes, receivedAt: at(7)))
        #expect(packet.rxTime == at(7))
        #expect(packet.nodeRxTime == nil)
    }

    @Test
    func `carries relay-node + next-hop + gateway id for trace reconstruction`() throws {
        let bytes = try envelope { packet in
            packet.decoded = dataMessage(port: .telemetryApp, payload: [0x01])
            packet.relayNode = 0xAB
            packet.nextHop = 0xCD
        }
        let decoder = PacketDecoder(keyStore: FakeKeyStore(), decryptor: FixedDecryptor(plaintext: []))
        let packet = try #require(try decoder.decode(serviceEnvelope: bytes, receivedAt: at(5)))
        #expect(packet.relayNode == 0xAB)
        #expect(packet.nextHop == 0xCD)
        #expect(packet.gatewayID == 0xA1B2_C3D4) // parsed from "!a1b2c3d4"
    }

    @Test
    func `gateway id parsing requires the bang prefix`() {
        #expect(PacketDecoder.parseGatewayID("!a1b2c3d4") == 0xA1B2_C3D4)
        #expect(PacketDecoder.parseGatewayID("a1b2c3d4") == nil)
    }

    @Test
    func `decrypts an encrypted packet using the channel key + decryptor`() throws {
        let inner = dataMessage(port: .positionApp, payload: [0xAA, 0xBB])
        let innerBytes = try [UInt8](inner.serializedData())
        let bytes = try envelope { packet in
            packet.encrypted = Data([0xDE, 0xAD]) // opaque ciphertext; FixedDecryptor maps it
        }
        let store = FakeKeyStore(keysByChannel: [8: ChannelKey(psk: Array(repeating: 0, count: 16))])
        let decoder = PacketDecoder(keyStore: store, decryptor: FixedDecryptor(plaintext: innerBytes))
        let packet = try #require(try decoder.decode(serviceEnvelope: bytes, receivedAt: at(20)))

        #expect(packet.wasEncrypted)
        #expect(packet.port == .position)
        #expect(packet.payload == [0xAA, 0xBB])
    }

    @Test
    func `an encrypted packet with no held key is skipped (nil, not an error)`() throws {
        let bytes = try envelope { packet in
            packet.encrypted = Data([0xDE, 0xAD])
        }
        let decoder = PacketDecoder(keyStore: FakeKeyStore(), decryptor: FixedDecryptor(plaintext: []))
        #expect(try decoder.decode(serviceEnvelope: bytes, receivedAt: at(0)) == nil)
    }

    @Test
    func `malformed envelope bytes throw rather than crash`() {
        let decoder = PacketDecoder(keyStore: FakeKeyStore(), decryptor: FixedDecryptor(plaintext: []))
        #expect(throws: PacketDecodeError.self) {
            _ = try decoder.decode(serviceEnvelope: [0xFF, 0xFF, 0xFF, 0xFF], receivedAt: at(0))
        }
    }

    @Test
    func `an unmodelled port keeps its raw number`() throws {
        let bytes = try envelope { packet in
            packet.decoded = dataMessage(port: .paxcounterApp, payload: [])
        }
        let decoder = PacketDecoder(keyStore: FakeKeyStore(), decryptor: FixedDecryptor(plaintext: []))
        let packet = try #require(try decoder.decode(serviceEnvelope: bytes, receivedAt: at(0)))
        #expect(packet.port == .other(PortNum.paxcounterApp.rawValue))
    }

    private func at(_ seconds: Double) -> Instant {
        Instant.epoch.adding(seconds: seconds)
    }
}
