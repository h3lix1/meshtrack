@testable import App
import Testing

@Suite("NodeShareQR")
struct NodeShareQRTests {
    @Test
    func `share URL encodes the node hex id and round-trips`() {
        #expect(NodeShareQR.shareURL(forNodeNum: 0xA1B2_C3D4) == "meshtrack://node/!a1b2c3d4")
        #expect(NodeShareQR.shareURL(forNodeNum: 0x09) == "meshtrack://node/!00000009")
    }

    @Test
    func `generates a non-empty QR image for a valid string`() throws {
        let image = try #require(NodeShareQR.cgImage(for: "meshtrack://node/!a1b2c3d4", size: 200))
        #expect(image.width > 0)
        #expect(image.height > 0)
    }

    @Test
    func `larger requested size yields a larger raster`() {
        let small = NodeShareQR.cgImage(for: "meshtrack://node/!a1b2c3d4", size: 100)
        let large = NodeShareQR.cgImage(for: "meshtrack://node/!a1b2c3d4", size: 400)
        let smallWidth = small?.width ?? 0
        let largeWidth = large?.width ?? 0
        #expect(largeWidth > smallWidth)
    }

    @Test
    func `rejects empty input and non-positive size`() {
        #expect(NodeShareQR.cgImage(for: "", size: 200) == nil)
        #expect(NodeShareQR.cgImage(for: "x", size: 0) == nil)
    }
}
