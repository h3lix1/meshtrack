// TimelineStore — the read-only history seam for VCR playback (G9).
//
// MeshStore exposes node/telemetry reads but no observation query yet, and the
// Store adapter is a shared file this worktree must not edit. So the timeline's
// read is added here as a focused extension over the public `writer`: fetch the
// observations in a time window, newest-bounded, mapped into the pure
// TimelineObservation corpus the reconstructor folds. GRDB stays behind this
// boundary; the VM and engine see only Domain/App types.

import Domain
import GRDB
import Persistence

/// A typed failure for the timeline history read.
public enum TimelineStoreError: Error, Equatable, Sendable {
    /// An observation row carried a gateway_id that was not a parseable node id.
    case malformedGateway(String)
}

public extension MeshStore {
    /// Load the observations whose receive time falls in `[since, until]`, oldest first,
    /// for replay. The window keys off our own `ingest_time` (frame-receipt clock), NOT
    /// the firmware `rx_time` — too many nodes report a skewed RTC, which scattered
    /// packets to the wrong moments on the scrubber. Pre-`ingest_time` rows have none, so
    /// they fall back to `rx_time` via COALESCE. `gateway_id` is stored as the hex node id
    /// string (e.g. "!a1b2c3d4") or a decimal node num; both are parsed to the numeric
    /// node id used as the position-map key. Rows with no gateway keep a nil gateway
    /// (drawn as a direct source→… edge by the trace builder).
    func timelineObservations(since: Instant, until: Instant) async throws -> [TimelineObservation] {
        let sinceNanos = since.nanosecondsSinceEpoch
        let untilNanos = until.nanosecondsSinceEpoch
        let rows: [ObservationRecord] = try await writer.read { db in
            try ObservationRecord
                .filter(sql: "COALESCE(ingest_time, rx_time) BETWEEN ? AND ?",
                        arguments: [sinceNanos, untilNanos])
                .order(sql: "COALESCE(ingest_time, rx_time)")
                .fetchAll(db)
        }
        return try rows.map { try Self.timelineObservation($0) }
    }

    /// Map a stored observation row into the pure replay corpus type. The replay clock is
    /// our `ingest_time` (frame receipt) so playback orders packets by when WE saw them,
    /// not the node's unreliable claimed `rx_time`; pre-`ingest_time` rows fall back to it.
    static func timelineObservation(_ record: ObservationRecord) throws -> TimelineObservation {
        try TimelineObservation(
            packetID: UInt32(truncatingIfNeeded: record.packet_id),
            fromNode: record.node_num,
            gatewayNode: parseGateway(record.gateway_id),
            relayNode: 0,
            hopStart: record.hop_start ?? 0,
            hopLimit: record.hop_limit ?? 0,
            rxTime: Instant(nanosecondsSinceEpoch: record.ingest_time ?? record.rx_time)
        )
    }

    /// Parse a stored gateway id ("!a1b2c3d4" hex, or decimal) into a node num.
    /// `nil`/empty → nil (no gateway). Anything non-numeric → typed error.
    private static func parseGateway(_ raw: String?) throws -> Int64? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("!") {
            let hex = String(raw.dropFirst())
            guard let value = UInt32(hex, radix: 16) else { throw TimelineStoreError.malformedGateway(raw) }
            return Int64(value)
        }
        guard let value = Int64(raw) else { throw TimelineStoreError.malformedGateway(raw) }
        return value
    }
}
