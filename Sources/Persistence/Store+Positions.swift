// MeshStore position-fix queries — split out of `Store.swift` so that file stays
// within the lint file/type-length caps. Everything goes through the public
// `writer`, so this is a plain same-module extension with no special access needs.

import Domain
import GRDB

public extension MeshStore {
    /// Every position fix for one node, time-ordered ascending (oldest first; the
    /// last element is the most recent).
    func positionFixes(forNode nodeNum: Int64) async throws -> [PositionFixRecord] {
        try await writer.read { db in
            try PositionFixRecord
                .filter(Column("node_num") == nodeNum)
                .order(Column("t"))
                .fetchAll(db)
        }
    }

    /// The single most-recent position fix for EVERY node, keyed by `node_num`, in one
    /// SQL round-trip. Replaces the live network view's N+1 pattern (`allNodes()` then
    /// `positionFixes(forNode:)` once per node) — that issued a query per node serially
    /// on the way to building the map, which thrashed the writer and the main actor under
    /// a populated mesh.
    ///
    /// The correlated subquery picks the row with the greatest `t` per node (ties broken
    /// by the larger `id`, mirroring `loadNodes()`'s old `max(by: { $0.t < $1.t })` which
    /// kept the later-inserted of two equal-`t` fixes). The `idx_position_fix_node_time`
    /// index on `(node_num, t)` serves the per-node max, so this stays cheap even with a
    /// long fix history. Nodes without any fix simply don't appear in the result.
    func latestPositionFixes() async throws -> [Int64: PositionFixRecord] {
        try await writer.read { db in
            let rows = try PositionFixRecord.fetchAll(db, sql: """
            SELECT pf.* FROM \(Table.positionFix) pf
            WHERE pf.id = (
                SELECT latest.id FROM \(Table.positionFix) latest
                WHERE latest.node_num = pf.node_num
                ORDER BY latest.t DESC, latest.id DESC
                LIMIT 1
            )
            """)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.node_num, $0) })
        }
    }
}
