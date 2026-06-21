import Domain
import Foundation
@testable import Ingest
import MeshProtos
import Testing

@Suite("Decode performance budget (SPEC §6.3/§6.4)")
struct DecodePerfTests {
    private struct EmptyKeyStore: KeyStore {
        func key(forChannelHash _: UInt32) -> ChannelKey? {
            nil
        }
    }

    private struct NoopDecryptor: PacketDecryptor {
        func decrypt(_ c: [UInt8], packetID _: UInt32, fromNode _: UInt32, key _: ChannelKey) -> [UInt8] {
            c
        }
    }

    private func envelopeBytes() throws -> [UInt8] {
        var data = DataMessage()
        data.portnum = .telemetryApp
        data.payload = Data([0x08, 0x01, 0x10, 0x02])
        var packet = MeshPacket()
        packet.from = 0xA1B2_C3D4
        packet.id = 42
        packet.channel = 8
        packet.decoded = data
        var envelope = ServiceEnvelope()
        envelope.packet = packet
        envelope.gatewayID = "!a1b2c3d4"
        return try [UInt8](envelope.serializedData())
    }

    @Test
    func `decode throughput stays above the budget (catches gross regressions)`() throws {
        let bytes = try envelopeBytes()
        let decoder = PacketDecoder(keyStore: EmptyKeyStore(), decryptor: NoopDecryptor())
        let iterations = 5000

        let elapsed = ContinuousClock().measure {
            for _ in 0 ..< iterations {
                _ = try? decoder.decode(serviceEnvelope: bytes, receivedAt: .epoch)
            }
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        let perSecond = Double(iterations) / max(seconds, 1e-9)

        // Generous floor (real throughput is ~100k+/sec); a regression below this
        // signals something badly wrong. Budget tracked in scoreboard.json.
        #expect(perSecond > 5000, "decode throughput \(Int(perSecond)) msgs/sec is below the 5000 budget")
    }
}
