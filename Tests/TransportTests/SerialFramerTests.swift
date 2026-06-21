import Testing
@testable import Transport

@Suite("SerialFramer — Meshtastic serial framing codec")
struct SerialFramerTests {
    // MARK: Helpers

    /// Build a well-formed frame: `[0x94, 0xC3, lenMSB, lenLSB, payload…]`.
    private func frame(_ payload: [UInt8]) -> [UInt8] {
        let length = payload.count
        return [
            SerialFraming.start1,
            SerialFraming.start2,
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF)
        ] + payload
    }

    // MARK: Single frame

    @Test
    func `a single complete frame in one chunk yields its payload`() {
        var framer = SerialFramer()
        let payload: [UInt8] = [0x10, 0x20, 0x30]
        let output = framer.push(frame(payload))
        #expect(output.frames == [payload])
        #expect(output.errors.isEmpty)
        #expect(!framer.hasBufferedBytes) // fully consumed
    }

    @Test
    func `an empty-payload frame is a valid frame`() {
        var framer = SerialFramer()
        // len == 0 → header only, payload is [].
        let output = framer.push([SerialFraming.start1, SerialFraming.start2, 0x00, 0x00])
        #expect(output.frames == [[]])
        #expect(output.errors.isEmpty)
        #expect(!framer.hasBufferedBytes)
    }

    // MARK: Split across chunks

    @Test
    func `a frame split byte-by-byte across chunks reassembles`() {
        var framer = SerialFramer()
        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let bytes = frame(payload)
        var produced: [[UInt8]] = []
        for (offset, byte) in bytes.enumerated() {
            let output = framer.push(byte: byte)
            produced.append(contentsOf: output.frames)
            // Only the final byte completes the frame; every earlier push is empty.
            if offset < bytes.count - 1 {
                #expect(output.frames.isEmpty)
            }
        }
        #expect(produced == [payload])
    }

    @Test
    func `a frame split mid-header across two chunks reassembles`() {
        var framer = SerialFramer()
        let payload: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]
        let bytes = frame(payload)
        // Split inside the 4-byte header (after START1).
        let first = Array(bytes[0 ..< 1])
        let rest = Array(bytes[1...])
        #expect(framer.push(first).frames.isEmpty)
        #expect(framer.hasBufferedBytes)
        #expect(framer.push(rest).frames == [payload])
    }

    @Test
    func `a frame split mid-payload across two chunks reassembles`() {
        var framer = SerialFramer()
        let payload: [UInt8] = Array(0 ..< 50).map(UInt8.init)
        let bytes = frame(payload)
        let split = 4 + 20 // header + first 20 payload bytes
        #expect(framer.push(Array(bytes[0 ..< split])).frames.isEmpty)
        #expect(framer.hasBufferedBytes)
        #expect(framer.push(Array(bytes[split...])).frames == [payload])
    }

    // MARK: Multiple frames in one chunk

    @Test
    func `multiple frames in one chunk all decode in order`() {
        var framer = SerialFramer()
        let p1: [UInt8] = [0xA0]
        let p2: [UInt8] = [0xB0, 0xB1]
        let p3: [UInt8] = [0xC0, 0xC1, 0xC2]
        let output = framer.push(frame(p1) + frame(p2) + frame(p3))
        #expect(output.frames == [p1, p2, p3])
        #expect(output.errors.isEmpty)
        #expect(!framer.hasBufferedBytes)
    }

    @Test
    func `a chunk with a whole frame plus a partial frame keeps the remainder`() {
        var framer = SerialFramer()
        let whole: [UInt8] = [0x11, 0x22]
        let next: [UInt8] = [0x33, 0x44, 0x55]
        let nextBytes = frame(next)
        // Feed: one whole frame + the header (only) of the next frame.
        let output = framer.push(frame(whole) + Array(nextBytes[0 ..< 4]))
        #expect(output.frames == [whole])
        #expect(framer.hasBufferedBytes) // partial next frame retained
        // Now deliver the rest of the second frame's payload.
        #expect(framer.push(Array(nextBytes[4...])).frames == [next])
    }

    // MARK: Bad-header resync

    @Test
    func `leading garbage before the magic is discarded`() {
        var framer = SerialFramer()
        let payload: [UInt8] = [0x77]
        let output = framer.push([0x00, 0xFF, 0x12] + frame(payload))
        #expect(output.frames == [payload])
        #expect(!framer.hasBufferedBytes)
    }

    @Test
    func `START1 not followed by START2 drops only START1 and resyncs`() {
        var framer = SerialFramer()
        let payload: [UInt8] = [0x42]
        // 0x94 0x94 0xC3 …: the first 0x94 is a false start; the SECOND 0x94 is
        // the real START1. Dropping one byte at a time must still sync here.
        let output = framer.push([SerialFraming.start1] + frame(payload))
        #expect(output.frames == [payload])
        #expect(!framer.hasBufferedBytes)
    }

    @Test
    func `a lone START1 byte is buffered until the next byte decides it`() {
        var framer = SerialFramer()
        // Only START1 so far: undecidable, must be retained (could become magic).
        #expect(framer.push(byte: SerialFraming.start1).frames.isEmpty)
        #expect(framer.hasBufferedBytes)
        // Next byte is NOT START2 → false start, drop START1, then a real frame.
        let payload: [UInt8] = [0x09]
        #expect(framer.push([0x00] + frame(payload)).frames == [payload])
    }

    @Test
    func `garbage between two valid frames does not lose the second frame`() {
        var framer = SerialFramer()
        let p1: [UInt8] = [0x01, 0x02]
        let p2: [UInt8] = [0x03, 0x04]
        let output = framer.push(frame(p1) + [0xDE, 0xAD, 0x94, 0x00] + frame(p2))
        #expect(output.frames == [p1, p2])
    }

    // MARK: Oversized-length rejection

    @Test
    func `a length over 512 is rejected and reported, then the stream resyncs`() {
        var framer = SerialFramer()
        // Declared length 513 (> 512): oversized.
        let badHeader: [UInt8] = [SerialFraming.start1, SerialFraming.start2, 0x02, 0x01]
        let good: [UInt8] = [0x5A]
        let output = framer.push(badHeader + frame(good))
        #expect(output.errors == [.oversizedLength(declared: 513, max: serialMaxFrameLength)])
        // After reporting, the framer resyncs past the bad header to the next frame.
        #expect(output.frames == [good])
    }

    @Test
    func `a length of exactly 512 is accepted (boundary)`() {
        var framer = SerialFramer()
        let payload = [UInt8](repeating: 0xEE, count: 512)
        let output = framer.push(frame(payload))
        #expect(output.frames == [payload])
        #expect(output.errors.isEmpty)
        #expect(serialMaxFrameLength == 512)
    }

    @Test
    func `a length of 513 across a fragmented header is still rejected`() {
        var framer = SerialFramer()
        // START1 alone, then START2 + length bytes split out: the framer must wait
        // for all four header bytes before judging length, and still reject 513.
        #expect(framer.push(byte: SerialFraming.start1).frames.isEmpty)
        #expect(framer.push(byte: SerialFraming.start2).frames.isEmpty)
        #expect(framer.push(byte: 0x02).frames.isEmpty)
        let output = framer.push(byte: 0x01) // completes header → length 513
        #expect(output.errors == [.oversizedLength(declared: 513, max: serialMaxFrameLength)])
        #expect(output.frames.isEmpty)
    }

    // MARK: Buffer management & misc

    @Test
    func `pushing an empty chunk yields nothing and is safe`() {
        var framer = SerialFramer()
        let output = framer.push([UInt8]())
        #expect(output.frames.isEmpty)
        #expect(output.errors.isEmpty)
        #expect(!framer.hasBufferedBytes)
    }

    @Test
    func `reset discards a buffered partial frame`() {
        var framer = SerialFramer()
        // Buffer a partial frame (header says 4 payload bytes; send only 1).
        let bytes = frame([0x01, 0x02, 0x03, 0x04])
        #expect(framer.push(Array(bytes[0 ..< 5])).frames.isEmpty)
        #expect(framer.hasBufferedBytes)
        framer.reset()
        #expect(!framer.hasBufferedBytes)
        // After reset, the trailing payload bytes are NOT reinterpreted as a frame;
        // a fresh well-formed frame still decodes cleanly.
        #expect(framer.push(frame([0x99])).frames == [[0x99]])
    }

    @Test
    func `a big-endian length is decoded MSB-first`() {
        var framer = SerialFramer()
        // 0x0102 == 258 bytes. Verify the framer reads MSB then LSB (not swapped).
        let payload = [UInt8](repeating: 0x7F, count: 0x0102)
        let output = framer.push(frame(payload))
        #expect(output.frames.count == 1)
        #expect(output.frames.first?.count == 258)
    }

    @Test
    func `state persists across pushes so interleaved partial frames are correct`() {
        var framer = SerialFramer()
        let p1: [UInt8] = [0x11, 0x12, 0x13]
        let p2: [UInt8] = [0x21, 0x22]
        let b1 = frame(p1)
        let b2 = frame(p2)
        // chunk A: all of frame1 + first half of frame2's header
        var produced: [[UInt8]] = []
        produced += framer.push(b1 + Array(b2[0 ..< 2])).frames
        // chunk B: rest of frame2
        produced += framer.push(Array(b2[2...])).frames
        #expect(produced == [p1, p2])
    }
}
