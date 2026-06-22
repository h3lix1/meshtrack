// The Store adapter: opens SQLite (WAL on disk, in-memory for tests), applies
// migrations, and exposes an actor-safe API. GRDB's database writers are
// thread-safe and Sendable, so `MeshStore` is a value type over a writer.

import Domain
import Foundation
import GRDB

/// Opens databases with schema v1 applied.
public enum DatabaseConnection {
    /// On-disk database in **WAL mode** (the shared collector/app store).
    public static func onDisk(path: String) throws -> DatabasePool {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: config)
        try MeshtrackMigrator.makeMigrator().migrate(pool)
        return pool
    }

    /// In-memory database for deterministic tests.
    public static func inMemory() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try MeshtrackMigrator.makeMigrator().migrate(queue)
        return queue
    }
}

/// Actor-safe store API over a GRDB writer. Timestamps cross this boundary as
/// `Domain.Instant`; rows persist the raw Int64 nanoseconds.
public struct MeshStore: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) {
        self.writer = writer
    }

    // MARK: Nodes

    /// Insert or update a node (keyed by `node_num`).
    public func upsertNode(_ node: NodeRecord) async throws {
        try await writer.write { db in try node.save(db) }
    }

    public func fetchNode(nodeNum: Int64) async throws -> NodeRecord? {
        try await writer.read { db in try NodeRecord.fetchOne(db, key: nodeNum) }
    }

    /// Atomically fetch-merge-upsert a node inside a SINGLE write transaction.
    ///
    /// `merge` receives the current row (or `fallback` when the node is new),
    /// mutates it in place, and the result is saved within the same transaction.
    /// Doing the read and the write under one lock prevents a concurrent
    /// `setOwnership`/admin write from being clobbered by a stale full-row
    /// snapshot read in an earlier transaction — the read-modify-write race that
    /// a separate `fetchNode` + `upsertNode` would expose. Returns the saved row.
    @discardableResult
    public func updateNode(
        nodeNum: Int64,
        orInsert fallback: @Sendable @escaping () -> NodeRecord,
        merge: @Sendable @escaping (inout NodeRecord) -> Void
    ) async throws -> NodeRecord {
        try await writer.write { db in
            var node = try NodeRecord.fetchOne(db, key: nodeNum) ?? fallback()
            merge(&node)
            try node.save(db)
            return node
        }
    }

    /// All nodes, most-recently-heard first (for the node list / dashboard).
    public func allNodes() async throws -> [NodeRecord] {
        try await writer.read { db in
            try NodeRecord.order(Column("last_heard_at").desc).fetchAll(db)
        }
    }

    /// Mark a node heard at `instant`, creating it if new. Liveness is computed
    /// by the collector, not the UI (SPEC §2.2).
    public func markHeard(nodeNum: Int64, at instant: Instant) async throws {
        let nanos = instant.nanosecondsSinceEpoch
        try await writer.write { db in
            if var node = try NodeRecord.fetchOne(db, key: nodeNum) {
                node.last_heard_at = nanos
                try node.update(db)
            } else {
                try NodeRecord(node_num: nodeNum, first_seen_at: nanos, last_heard_at: nanos).insert(db)
            }
        }
    }

    // MARK: Ownership (ADR 0008)

    /// Set a node's ownership flags (single or bulk). Updating only the columns
    /// that are provided (`nil` leaves a flag unchanged), so callers can flip
    /// "mine" without touching "managed" and vice-versa. Throws
    /// `StoreError.nodeNotFound` for an unknown node.
    public func setOwnership(nodeNum: Int64, isMine: Bool? = nil, isManaged: Bool? = nil) async throws {
        try await writer.write { db in
            guard var node = try NodeRecord.fetchOne(db, key: nodeNum) else {
                throw StoreError.nodeNotFound(nodeNum: nodeNum)
            }
            if let isMine { node.is_mine = isMine }
            if let isManaged { node.is_managed = isManaged }
            try node.update(db)
        }
    }

    /// Apply ownership flags to many nodes at once (bulk-classify UI). Unknown
    /// node_nums are skipped; returns the count actually updated.
    @discardableResult
    public func setOwnership(
        nodeNums: [Int64],
        isMine: Bool? = nil,
        isManaged: Bool? = nil
    ) async throws -> Int {
        try await writer.write { db in
            var updated = 0
            for nodeNum in nodeNums {
                guard var node = try NodeRecord.fetchOne(db, key: nodeNum) else { continue }
                if let isMine { node.is_mine = isMine }
                if let isManaged { node.is_managed = isManaged }
                try node.update(db)
                updated += 1
            }
            return updated
        }
    }

    /// Whether a node is managed (gates ownership-sensitive rules). Unknown nodes
    /// are unmanaged.
    public func isManaged(nodeNum: Int64) async throws -> Bool {
        try await writer.read { db in
            try NodeRecord.fetchOne(db, key: nodeNum)?.is_managed ?? false
        }
    }

    /// The node_nums of every managed node (the rule engine's eligibility set).
    public func managedNodeNums() async throws -> [Int64] {
        try await writer.read { db in
            try Int64.fetchAll(
                db,
                sql: "SELECT node_num FROM \(Table.node) WHERE is_managed = 1"
            )
        }
    }

    /// Every node the operator marked as theirs ("My Nodes" filter, ADR 0008).
    public func myNodes() async throws -> [NodeRecord] {
        try await writer.read { db in
            try NodeRecord
                .filter(Column("is_mine") == true)
                .order(Column("last_heard_at").desc)
                .fetchAll(db)
        }
    }

    // MARK: Observations (provenance + dedup)

    /// Record one observation. Throws `StoreError.duplicate` if the
    /// `(packet_id, node_num)` dedup index rejects it (SPEC §2.4).
    @discardableResult
    public func recordObservation(_ observation: ObservationRecord) async throws -> Int64 {
        do {
            return try await writer.write { db in
                var record = observation
                try record.insert(db)
                return record.id ?? db.lastInsertedRowID
            }
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            throw StoreError.duplicate(details: error.message ?? "unique constraint violation")
        }
    }

    // MARK: Messages (monitor-only, ADR 0006)

    /// Append a decoded text message, idempotent on `(packet_id, from_num)`
    /// (schema v5). A re-delivery of the same logical message — e.g. via a
    /// different gateway after a reconnect, which a fresh in-memory `DedupWindow`
    /// would re-admit — is silently ignored rather than duplicating a chat line.
    /// Returns the new row id, or `0` when the insert was ignored as a duplicate.
    @discardableResult
    public func recordMessage(_ message: MessageRecord) async throws -> Int64 {
        try await writer.write { db in
            var record = message
            try record.insert(db, onConflict: .ignore)
            return db.changesCount > 0 ? (record.id ?? db.lastInsertedRowID) : 0
        }
    }

    /// Messages on a channel, oldest-first (the Channels view feed). The `id`
    /// tie-break makes ordering deterministic when several messages share an
    /// `rx_time`, so the transcript does not flicker between loads (Finding 13).
    public func messages(channel: Int64, limit: Int = 200) async throws -> [MessageRecord] {
        try await writer.read { db in
            try MessageRecord
                .filter(Column("channel") == channel)
                .order(Column("rx_time").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
                .reversed()
        }
    }

    /// The most-recent messages across all channels, newest-first. The `id`
    /// tie-break keeps ordering stable for equal `rx_time` (Finding 13).
    public func recentMessages(limit: Int = 200) async throws -> [MessageRecord] {
        try await writer.read { db in
            try MessageRecord
                .order(Column("rx_time").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: Time-series

    /// Append a telemetry sample, idempotent on `(node_num, t, kind, key)`
    /// (schema v5). A re-delivered packet (e.g. via a different gateway after a
    /// reconnect) is silently ignored rather than double-counting the metric.
    /// Returns the new row id, or `0` when the insert was ignored as a duplicate.
    @discardableResult
    public func appendTelemetry(_ telemetry: TelemetryRecord) async throws -> Int64 {
        try await writer.write { db in
            var record = telemetry
            try record.insert(db, onConflict: .ignore)
            return db.changesCount > 0 ? (record.id ?? db.lastInsertedRowID) : 0
        }
    }

    /// Append a position fix, idempotent on `(node_num, t)` (schema v5). A
    /// re-delivered packet is silently ignored rather than duplicating the fix.
    /// Returns the new row id, or `0` when the insert was ignored as a duplicate.
    @discardableResult
    public func appendPositionFix(_ fix: PositionFixRecord) async throws -> Int64 {
        try await writer.write { db in
            var record = fix
            try record.insert(db, onConflict: .ignore)
            return db.changesCount > 0 ? (record.id ?? db.lastInsertedRowID) : 0
        }
    }

    public func telemetry(forNode nodeNum: Int64) async throws -> [TelemetryRecord] {
        try await writer.read { db in
            try TelemetryRecord
                .filter(Column("node_num") == nodeNum)
                .order(Column("t"))
                .fetchAll(db)
        }
    }

    public func positionFixes(forNode nodeNum: Int64) async throws -> [PositionFixRecord] {
        try await writer.read { db in
            try PositionFixRecord
                .filter(Column("node_num") == nodeNum)
                .order(Column("t"))
                .fetchAll(db)
        }
    }

    // MARK: Retention & rollups (SPEC §5)

    /// Roll up raw telemetry into the hourly + daily downsample tables for every
    /// COMPLETE bucket (range entirely before `now`). Idempotent (upserts).
    public func rollupTelemetry(now: Instant) async throws {
        let nowNanos = now.nanosecondsSinceEpoch
        try await writer.write { db in
            try Self.rollup(db, into: Table.telemetryHourly, bucketNanos: 3_600_000_000_000, now: nowNanos)
            try Self.rollup(db, into: Table.telemetryDaily, bucketNanos: 86_400_000_000_000, now: nowNanos)
        }
    }

    /// Delete raw telemetry older than `cutoff` (retention_raw). Run AFTER
    /// `rollupTelemetry` so the downsampled rollups survive.
    public func pruneRawTelemetry(olderThan cutoff: Instant) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM \(Table.telemetry) WHERE t < ?",
                arguments: [cutoff.nanosecondsSinceEpoch]
            )
        }
    }

    public func hourlyTelemetry(forNode nodeNum: Int64) async throws -> [TelemetryRollupRecord] {
        try await rollups(Table.telemetryHourly, nodeNum: nodeNum)
    }

    public func dailyTelemetry(forNode nodeNum: Int64) async throws -> [TelemetryRollupRecord] {
        try await rollups(Table.telemetryDaily, nodeNum: nodeNum)
    }

    private func rollups(_ table: String, nodeNum: Int64) async throws -> [TelemetryRollupRecord] {
        try await writer.read { db in
            try TelemetryRollupRecord.fetchAll(
                db,
                sql: "SELECT * FROM \(table) WHERE node_num = ? ORDER BY bucket",
                arguments: [nodeNum]
            )
        }
    }

    private static func rollup(_ db: Database, into table: String, bucketNanos: Int64, now: Int64) throws {
        try db.execute(sql: """
        INSERT INTO \(table) (node_num, bucket, kind, key, min_value, max_value, avg_value, sample_count)
        SELECT node_num, (t / \(bucketNanos)) * \(bucketNanos) AS bucket, kind, key,
               MIN(value), MAX(value), AVG(value), COUNT(*)
        FROM \(Table.telemetry)
        WHERE (t / \(bucketNanos)) * \(bucketNanos) + \(bucketNanos) <= \(now)
        GROUP BY node_num, bucket, kind, key
        ON CONFLICT(node_num, bucket, kind, key)
        DO UPDATE SET min_value = excluded.min_value, max_value = excluded.max_value,
                      avg_value = excluded.avg_value, sample_count = excluded.sample_count
        """)
    }

    // MARK: Export / backup (SPEC §6 / Phase 6)

    /// Back up the live database to a file at `path` (a consistent SQLite copy,
    /// safe while the store is in use). Overwrites any existing file.
    public func backup(toPath path: String) async throws {
        let destination = try DatabaseQueue(path: path)
        try writer.backup(to: destination)
    }
}
