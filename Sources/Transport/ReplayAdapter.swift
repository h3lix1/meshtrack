// ReplayAdapter — the `MeshTransport` for golden-corpus replay (SPEC §6, tier 4).
//
// Loads a corpus directory (meta.json + frames.ndjson) and emits its frames, in
// `seq` order, through `frames()`. Each emitted `InboundFrame` carries the raw
// on-the-wire payload bytes (NO protobuf decode — that is the Phase 1 pipeline)
// and `receivedAt = Instant(nanosecondsSinceEpoch: rx_time_ns)`.
//
// Crucially, replay also drives a `Domain.InjectedClock`: before each frame is
// yielded the clock is pinned to that frame's `rx_time_ns`, so every downstream
// detector/evaluator sees *replay* time, not the host wall clock. This makes the
// integration tier deterministic.

import Domain
import Foundation

/// Replays a golden corpus through the `MeshTransport` port, driving an injected
/// clock from each frame's receive time.
public struct ReplayAdapter: MeshTransport {
    /// The loaded, validated corpus (frames already sorted by `seq`).
    public let corpus: Corpus
    /// The clock driven from `rx_time_ns`. Downstream reads time through this.
    public let clock: InjectedClock

    /// Build an adapter from an already-loaded corpus.
    ///
    /// - Parameters:
    ///   - corpus: a validated corpus (see `Corpus.load`).
    ///   - clock: the clock to advance from each frame's `rx_time_ns`. Defaults
    ///     to a fresh `InjectedClock` exposed via the `clock` property so callers
    ///     that don't inject one can still observe replay time.
    public init(corpus: Corpus, clock: InjectedClock = InjectedClock()) {
        self.corpus = corpus
        self.clock = clock
    }

    /// Build an adapter by loading a corpus directory.
    ///
    /// - Throws: `ReplayError` if the directory/files are missing or malformed.
    public init(directory url: URL, clock: InjectedClock = InjectedClock()) throws {
        try self.init(corpus: Corpus.load(directory: url), clock: clock)
    }

    /// The instant of the last frame, or `.epoch` for an empty corpus. After the
    /// stream finishes, `clock.now()` equals this.
    public var lastInstant: Instant {
        guard let last = corpus.frames.last else { return .epoch }
        return Instant(nanosecondsSinceEpoch: last.rxTimeNs)
    }

    /// Emit every corpus frame in `seq` order. For each frame the injected clock
    /// is pinned to `rx_time_ns` *before* the frame is yielded, so a consumer
    /// reading the clock as it processes a frame sees that frame's time. The
    /// stream finishes after the last frame.
    public func frames() -> AsyncStream<InboundFrame> {
        let corpus = corpus
        let clock = clock
        return AsyncStream { continuation in
            for record in corpus.frames {
                let receivedAt = Instant(nanosecondsSinceEpoch: record.rxTimeNs)
                clock.set(receivedAt)
                // Payload base64 was validated at load; decode is total here, but
                // fall back to empty rather than force-unwrapping on the seam.
                let payload = (try? Corpus.payloadBytes(of: record)) ?? []
                continuation.yield(
                    InboundFrame(
                        transport: record.transport,
                        topic: record.topic,
                        payload: payload,
                        receivedAt: receivedAt,
                        gatewayID: record.gatewayID
                    )
                )
            }
            continuation.finish()
        }
    }
}
