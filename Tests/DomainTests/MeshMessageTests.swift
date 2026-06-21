@testable import Domain
import Testing

@Suite("MeshMessage (monitor-only decoded text)")
struct MeshMessageTests {
    private func message(to: UInt32, body: String) -> MeshMessage {
        MeshMessage(
            packetID: 1, from: 7, to: to, channel: 8, channelName: "MediumFast",
            body: body, rxTime: .epoch
        )
    }

    @Test
    func `a broadcast is not a direct message`() {
        #expect(message(to: meshBroadcastAddress, body: "hi all").isDirectMessage == false)
    }

    @Test
    func `a message to a specific node is a direct message`() {
        #expect(message(to: 99, body: "hi you").isDirectMessage == true)
    }

    @Test
    func `mentions extracts @names until whitespace, in order`() {
        let msg = message(to: meshBroadcastAddress, body: "hey @SFGate and @OAK1, status?")
        #expect(msg.mentions == ["SFGate", "OAK1"])
    }

    @Test
    func `a bare @ with no name yields no mention`() {
        #expect(message(to: meshBroadcastAddress, body: "email me @ home").mentions.isEmpty)
    }

    @Test
    func `a body with no mentions yields none`() {
        #expect(message(to: meshBroadcastAddress, body: "plain text").mentions.isEmpty)
    }

    @Test
    func `a mention at end-of-body is captured`() {
        #expect(message(to: meshBroadcastAddress, body: "ping @BASE").mentions == ["BASE"])
    }
}
