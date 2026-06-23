// AlertsStore — the read/write seam for the alerts console + arming flow (G5).
//
// `MeshStore` (the shared Persistence adapter, frozen for this worktree) creates
// the `alert` / `alert_rule` / `arming` tables but exposes no accessors for them
// yet. So — exactly like `TimelineStore` did for the VCR observation read — the
// alert and arming round-trips live here as a focused extension over the public
// `writer`. GRDB stays behind this boundary; the view models above see only
// Domain/App types and `AlertRecord` / `ArmingRecord` value types.

import Domain
import GRDB
import Persistence

/// Typed failures for the alerts / arming store seam. No `try!`/force-unwrap in
/// production code — callers get a precise, `Sendable` error instead.
public enum AlertsStoreError: Error, Equatable, Sendable {
    /// An arming capture was requested for a node with no stored position fix.
    case noPositionFix(nodeNum: Int64)
}

public extension MeshStore {
    // MARK: Alerts

    /// Every tracked alert, newest-fired first (the console feed). The console
    /// groups/sorts these in memory; the store just returns the corpus.
    func allAlerts() async throws -> [AlertRecord] {
        try await writer.read { db in
            try AlertRecord.order(Column("fired_at").desc).fetchAll(db)
        }
    }

    /// Insert or update an alert. Keyed on `id` when present; otherwise inserts a
    /// new row and returns its rowid. Used by the engine→store reconcile and by
    /// the console's ack/snooze/resolve actions.
    @discardableResult
    func saveAlert(_ alert: AlertRecord) async throws -> Int64 {
        try await writer.write { db in
            var record = alert
            try record.save(db)
            return record.id ?? db.lastInsertedRowID
        }
    }

    /// The alert row for a (type, node), if one is tracked. Used to round-trip an
    /// ack/snooze/resolve back onto the persisted row.
    func alert(type: String, nodeNum: Int64) async throws -> AlertRecord? {
        try await writer.read { db in
            try AlertRecord
                .filter(Column("type") == type && Column("node_num") == nodeNum)
                .order(Column("fired_at").desc)
                .fetchOne(db)
        }
    }

    // MARK: Arming (movement anchor)

    /// The arming row for a node, if armed/anchored.
    func arming(nodeNum: Int64) async throws -> ArmingRecord? {
        try await writer.read { db in try ArmingRecord.fetchOne(db, key: nodeNum) }
    }

    /// All arming rows (the arming console list).
    func allArming() async throws -> [ArmingRecord] {
        try await writer.read { db in
            try ArmingRecord.order(Column("node_num")).fetchAll(db)
        }
    }

    /// Insert or update an arming row (capture / disarm / state transition).
    func saveArming(_ arming: ArmingRecord) async throws {
        try await writer.write { db in try arming.save(db) }
    }

    /// The most-recent stored position fix for a node, the anchor source when
    /// capturing. `nil` if the node has never reported a position.
    func latestPositionFix(nodeNum: Int64) async throws -> PositionFixRecord? {
        try await writer.read { db in
            try PositionFixRecord
                .filter(Column("node_num") == nodeNum)
                .order(Column("t").desc)
                .fetchOne(db)
        }
    }
}
