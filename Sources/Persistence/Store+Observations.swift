// MeshStore observation reads — split out of `Store.swift` (lint file/type-length).
//
// The ingest pipeline writes an `ObservationRecord` for every reception
// (`recordObservation`), but until Phase 10 there was no READ path, so the per-node
// Analytics deep-dive (signal / hops / peers / activity) had no store-backed source
// and rendered empty in the live app (item 7). This adds the fetch the analytics VM
// loads on appear. Everything goes through the public `writer`, so this is a plain
// same-module extension.

import GRDB

public extension MeshStore {
    /// The node's stored observations, most-recent `limit` rows returned time-ordered
    /// ASCENDING (oldest first) so the activity heatmap reads left-to-right. Powers the
    /// SNR/RSSI, hop, peer and activity analytics tabs.
    func observations(forNode nodeNum: Int64, limit: Int = 5000) async throws -> [ObservationRecord] {
        try await writer.read { db in
            let recent = try ObservationRecord
                .filter(Column("node_num") == nodeNum)
                .order(Column("rx_time").desc)
                .limit(limit)
                .fetchAll(db)
            return Array(recent.reversed())
        }
    }
}
