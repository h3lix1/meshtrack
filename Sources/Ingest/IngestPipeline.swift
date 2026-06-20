// IngestPipeline — the seam that turns a stream of inbound frames into persisted
// state. This is the Phase 0 proof that the hexagonal wiring closes end-to-end:
// a `MeshTransport` (e.g. ReplayAdapter over a golden corpus) feeds frames, and
// nodes land in the `MeshStore`.
//
// Phase 0 attributes each frame to a node via its provenance — the gateway
// USERID (`!hexid`) carried on the frame. Decoding the encrypted ServiceEnvelope
// / MeshPacket payload (to attribute by the packet's `from_num`, count telemetry,
// and dedup on `packet_id`) is the Phase 1 pipeline; this seam is where it lands.

import Domain
import Persistence
import Transport

/// What an ingest run did. Returned so callers/tests can assert on outcomes
/// without reaching into the store.
public struct IngestSummary: Sendable, Equatable {
    /// Total frames pulled from the transport.
    public var framesProcessed: Int
    /// Frames that carried a derivable node identity and were persisted.
    public var framesAttributed: Int

    public init(framesProcessed: Int = 0, framesAttributed: Int = 0) {
        self.framesProcessed = framesProcessed
        self.framesAttributed = framesAttributed
    }
}

/// Consumes a `MeshTransport` and persists the nodes it observes.
public struct IngestPipeline: Sendable {
    private let store: MeshStore

    public init(store: MeshStore) {
        self.store = store
    }

    /// Drain every frame from `transport`, marking each attributable node heard at
    /// the frame's receive time. Returns a summary of what was processed.
    @discardableResult
    public func run(_ transport: any MeshTransport) async throws -> IngestSummary {
        var summary = IngestSummary()
        for await frame in transport.frames() {
            summary.framesProcessed += 1
            guard let nodeNum = Self.nodeNum(fromHexID: frame.gatewayID) else { continue }
            try await store.markHeard(nodeNum: nodeNum, at: frame.receivedAt)
            summary.framesAttributed += 1
        }
        return summary
    }

    /// Parse a node's numeric id from a Meshtastic `!hexid` (e.g. `"!a1b2c3d4"`).
    ///
    /// Phase 0 derives identity from frame provenance (the gateway USERID); the
    /// originating node's `from_num` arrives with payload decode in Phase 1.
    public static func nodeNum(fromHexID hexID: String?) -> Int64? {
        guard var hex = hexID else { return nil }
        if hex.hasPrefix("!") { hex.removeFirst() }
        guard !hex.isEmpty else { return nil }
        return Int64(hex, radix: 16)
    }
}
