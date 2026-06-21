// SerialFramer — a PURE, incremental codec for the Meshtastic serial stream.
//
// Meshtastic frames each protobuf packet on the wire as:
//
//     [0x94, 0xC3, lenMSB, lenLSB, <len bytes of protobuf>]
//
// (`START1=0x94`, `START2=0xC3`, then a big-endian 16-bit length, then exactly
// that many payload bytes.) The same framing is used over USB serial and over
// the BLE FromRadio characteristic, so this codec is the shared, tested core
// behind both `SerialAdapter` and `BLEAdapter`.
//
// The framer is *incremental*: callers feed arbitrary byte chunks (a serial read
// rarely lands on a frame boundary) and get back zero or more complete payloads.
// It owns a small internal buffer so a frame may span any number of chunks. It
// is a `struct` with `mutating func push` — no Foundation, no I/O, no clock —
// which makes it exhaustively unit-testable and keeps Transport's coverage core
// honest.
//
// Resynchronisation: real serial lines drop bytes and power-cycle mid-frame, so
// the framer never trusts the stream. It scans for the 2-byte magic and discards
// any leading garbage one byte at a time (so a `0x94` that is *not* followed by
// `0xC3` is dropped, but the byte after it is re-examined as a possible new
// START1 — a run like `94 94 C3 …` still syncs). Oversized lengths are rejected
// as a framing error (a desynced stream can otherwise claim a 64 KiB frame),
// and the framer resyncs past the bad header rather than blocking.

/// The maximum payload length the framer will accept, in bytes.
///
/// Meshtastic's `FromRadio`/`ToRadio` messages are bounded well under this; a
/// larger declared length means the stream is desynced (or hostile), so the
/// framer treats it as a framing error and resyncs. Matches the firmware's
/// `MAX_TO_FROM_RADIO_SIZE` ceiling.
public let serialMaxFrameLength = 512

/// A problem the framer detected in the byte stream. Surfaced so an adapter can
/// log/count desyncs; the framer always recovers and keeps producing frames.
public enum SerialFramingError: Error, Equatable, Sendable {
    /// A valid magic header declared a length greater than ``serialMaxFrameLength``.
    /// The framer discards the header and resumes scanning for the next magic.
    case oversizedLength(declared: Int, max: Int)
}

/// The two framing bytes that prefix every Meshtastic serial frame.
public enum SerialFraming {
    /// First magic byte (`START1`).
    public static let start1: UInt8 = 0x94
    /// Second magic byte (`START2`).
    public static let start2: UInt8 = 0xC3
    /// Bytes of fixed header before the payload: `START1 START2 lenMSB lenLSB`.
    public static let headerLength = 4
}

/// An incremental decoder for the Meshtastic serial framing.
///
/// Feed it bytes with ``push(_:)`` (or ``push(byte:)``); it returns any payloads
/// that completed within that call. Internally it buffers a partial frame across
/// calls, so frames may be split across chunks arbitrarily and several frames may
/// arrive in one chunk. The framer is a value type with no effects: identical
/// input always yields identical output.
public struct SerialFramer: Sendable {
    /// Bytes received but not yet consumed into a completed frame. Holds at most
    /// one in-progress frame (header + however many payload bytes have arrived).
    private var buffer: [UInt8] = []

    public init() {}

    /// Outcome of feeding a chunk: the payloads that completed, plus any framing
    /// errors observed (e.g. an oversized declared length that forced a resync).
    public struct Output: Equatable, Sendable {
        /// Completed payloads, in stream order. Each is the protobuf body only —
        /// the magic + length header has been stripped.
        public let frames: [[UInt8]]
        /// Framing errors detected while parsing this chunk. The framer has
        /// already recovered from each; they are reported for observability.
        public let errors: [SerialFramingError]

        public init(frames: [[UInt8]], errors: [SerialFramingError] = []) {
            self.frames = frames
            self.errors = errors
        }
    }

    /// Feed a chunk of bytes and decode every frame that completes.
    ///
    /// Bytes that don't complete a frame are retained for the next call. Leading
    /// garbage and bad headers are discarded with resync; an oversized length is
    /// reported in ``Output/errors`` and skipped.
    ///
    /// - Parameter bytes: the chunk just read from the transport (may be empty,
    ///   may contain partial, whole, and multiple frames in any mix).
    /// - Returns: the frames completed by this chunk and any framing errors.
    public mutating func push(_ bytes: some Sequence<UInt8>) -> Output {
        buffer.append(contentsOf: bytes)
        return drain()
    }

    /// Feed a single byte. Convenience over ``push(_:)`` for byte-at-a-time
    /// sources and tests.
    public mutating func push(byte: UInt8) -> Output {
        push(CollectionOfOne(byte))
    }

    /// Discard any buffered partial frame, e.g. after a reconnect. Does not emit.
    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    /// Whether a partial frame (or unresolved bytes) is currently buffered.
    public var hasBufferedBytes: Bool {
        !buffer.isEmpty
    }

    /// Consume as many complete frames as the buffer currently allows.
    ///
    /// Loops because one chunk can finish several frames. Each iteration either
    /// (a) finds the buffer too short to decide and stops, (b) drops a byte to
    /// resync, (c) records an oversized-length error and skips the header, or
    /// (d) emits a completed payload and advances past it.
    private mutating func drain() -> Output {
        var frames: [[UInt8]] = []
        var errors: [SerialFramingError] = []

        var index = 0
        while index < buffer.count {
            // Need START1 to even begin. Drop one leading byte at a time so the
            // *next* byte can still be a fresh START1.
            guard buffer[index] == SerialFraming.start1 else {
                index += 1
                continue
            }
            // Only START1 so far: wait for more bytes before judging the header.
            guard index + 1 < buffer.count else { break }
            // START1 not followed by START2 → false start. Drop START1 only and
            // re-examine from the next byte (it might itself be a START1).
            guard buffer[index + 1] == SerialFraming.start2 else {
                index += 1
                continue
            }
            // Have the magic; need both length bytes to know the frame size.
            guard index + 3 < buffer.count else { break }
            let declared = Int(buffer[index + 2]) << 8 | Int(buffer[index + 3])
            guard declared <= serialMaxFrameLength else {
                // Desynced or hostile length. Report and skip past START1 to
                // resync (don't trust the rest of this "header").
                errors.append(.oversizedLength(declared: declared, max: serialMaxFrameLength))
                index += 1
                continue
            }
            let payloadStart = index + SerialFraming.headerLength
            let payloadEnd = payloadStart + declared
            // Whole payload not in yet: keep the partial frame for the next push.
            guard payloadEnd <= buffer.count else { break }
            frames.append(Array(buffer[payloadStart ..< payloadEnd]))
            index = payloadEnd
        }

        // Drop everything we consumed/skipped; retain the unresolved tail.
        if index > 0 {
            buffer.removeFirst(index)
        }
        return Output(frames: frames, errors: errors)
    }
}
