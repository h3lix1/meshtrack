import Domain
import Testing

@Suite("NodeID hex formatting (Finding 14 — shared node-id helper)")
struct NodeIDTests {
    @Test
    func `hex is the ! prefix plus 8 lowercase hex digits`() {
        #expect(NodeID.hex(0x1234_5678) == "!12345678")
        #expect(NodeID.hex(0xABCD_EF01) == "!abcdef01")
    }

    @Test
    func `hex zero-pads values whose hex is fewer than 8 digits`() {
        #expect(NodeID.hex(0) == "!00000000")
        #expect(NodeID.hex(0xFF) == "!000000ff")
        #expect(NodeID.hex(0x1234) == "!00001234")
    }

    @Test
    func `hex of UInt32 max is all f`() {
        #expect(NodeID.hex(UInt32.max) == "!ffffffff")
    }

    @Test
    func `shortHex is 4 lowercase hex digits of the low 16 bits, no prefix`() {
        #expect(NodeID.shortHex(0xC3D4) == "c3d4")
        #expect(NodeID.shortHex(0x1234_5678) == "5678") // only the low 16 bits
    }

    @Test
    func `shortHex zero-pads values whose hex is fewer than 4 digits`() {
        #expect(NodeID.shortHex(0) == "0000")
        #expect(NodeID.shortHex(0x5) == "0005")
        #expect(NodeID.shortHex(0xFF) == "00ff")
    }

    @Test
    func `shortHex of UInt32 max is ffff`() {
        #expect(NodeID.shortHex(UInt32.max) == "ffff")
    }
}
