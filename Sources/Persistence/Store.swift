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

    // MARK: Time-series

    @discardableResult
    public func appendTelemetry(_ telemetry: TelemetryRecord) async throws -> Int64 {
        try await writer.write { db in
            var record = telemetry
            try record.insert(db)
            return record.id ?? db.lastInsertedRowID
        }
    }

    @discardableResult
    public func appendPositionFix(_ fix: PositionFixRecord) async throws -> Int64 {
        try await writer.write { db in
            var record = fix
            try record.insert(db)
            return record.id ?? db.lastInsertedRowID
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
