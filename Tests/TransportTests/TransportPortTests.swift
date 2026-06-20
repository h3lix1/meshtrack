import Domain
import Testing
@testable import Transport

@Suite("MeshTransport port")
struct TransportPortTests {
    @Test
    func `InboundFrame preserves payload and provenance`() {
        let frame = InboundFrame(
            transport: .replay,
            topic: "msh/US/2/e/LongFast/!abcd",
            payload: [0x01, 0x02, 0x03],
            receivedAt: Instant(nanosecondsSinceEpoch: 10),
            gatewayID: "!gateway1"
        )
        #expect(frame.payload == [0x01, 0x02, 0x03])
        #expect(frame.transport == .replay)
        #expect(frame.topic == "msh/US/2/e/LongFast/!abcd")
        #expect(frame.gatewayID == "!gateway1")
        #expect(frame.receivedAt == Instant(nanosecondsSinceEpoch: 10))
    }

    @Test
    func `Transport enumerates all known sources`() {
        #expect(InboundFrame.Transport.allCases.count == 4)
    }
}
