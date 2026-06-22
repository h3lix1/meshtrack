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

    /// Append a decoded text message. Cross-run/reconnect idempotency is enforced
    /// by the windowed `admitExtraction` ledger the pipeline consults BEFORE this
    /// call (schema v6, Finding 5), not by a permanent unique index — so a legitimate
    /// later message reusing the same `(packet_id, from_num)` after the dedup window
    /// is recorded rather than silently dropped forever. Returns the new row id.
    @discardableResult
    public func recordMessage(_ message: MessageRecord) async throws -> Int64 {
        try await writer.write { db in
            var record = message
            try record.insert(db)
            return record.id ?? db.lastInsertedRowID
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

    /// Append a telemetry sample. Re-delivery idempotency is enforced once per
    /// packet by the windowed `admitExtraction` ledger the pipeline consults before
    /// extracting (schema v6, Finding 5) — not by a permanent `(node_num, t, kind,
    /// key)` unique index, which would also have dropped two genuinely-distinct
    /// samples that share that coarse key. Returns the new row id.
    @discardableResult
    public func appendTelemetry(_ telemetry: TelemetryRecord) async throws -> Int64 {
        try await writer.write { db in
            var record = telemetry
            try record.insert(db)
            return record.id ?? db.lastInsertedRowID
        }
    }

    /// Append a position fix. Re-delivery idempotency is enforced once per packet by
    /// the windowed `admitExtraction` ledger the pipeline consults before extracting
    /// (schema v6, Finding 5), not by a permanent `(node_num, t)` unique index that
    /// would also drop two distinct fixes a node reported at the same instant.
    /// Returns the new row id.
    @discardableResult
    public func appendPositionFix(_ fix: PositionFixRecord) async throws -> Int64 {
        try await writer.write { db in
            var record = fix
            try record.insert(db)
            return record.id ?? db.lastInsertedRowID
        }
    }

    // MARK: Windowed extraction dedup (SPEC §2.4, schema v6)

    /// Atomically admit (or reject) the once-only extraction of a packet, keyed by
    /// its identity `(from_num, packet_id)`, against the sliding `windowSeconds`
    /// window — the DURABLE companion to the pipeline's in-memory `DedupWindow`,
    /// which is recreated each `run()` and so cannot span a reconnect.
    ///
    /// Returns `true` when this is the first sighting within the window (proceed to
    /// extract telemetry/position/message) and `false` when the same identity was
    /// extracted less than `windowSeconds` ago (skip — a re-delivery). A first
    /// sighting OR an expired one records/slides the ledger row; expired rows are
    /// pruned so the ledger stays bounded. This intentionally lets the SAME identity
    /// recur after the window (legitimate packet-id reuse) — the bug the v5 permanent
    /// unique index caused (Finding 5).
    public func admitExtraction(
        packetID: Int64,
        fromNum: Int64,
        at instant: Instant,
        windowSeconds: Double = 600
    ) async throws -> Bool {
        let key = "\(fromNum):\(packetID)"
        let now = instant.nanosecondsSinceEpoch
        let windowNanos = Int64((windowSeconds * 1_000_000_000).rounded())
        return try await writer.write { db in
            // Prune everything older than the window relative to `now` (bounded size).
            try db.execute(
                sql: "DELETE FROM \(Table.dedupSeen) WHERE last_seen_at < ?",
                arguments: [now - windowNanos]
            )
            let previous = try Int64.fetchOne(
                db,
                sql: "SELECT last_seen_at FROM \(Table.dedupSeen) WHERE key = ?",
                arguments: [key]
            )
            if let previous, now - previous <= windowNanos {
                // Seen within the window — a duplicate. Slide the window forward.
                try db.execute(
                    sql: "UPDATE \(Table.dedupSeen) SET last_seen_at = ? WHERE key = ?",
                    arguments: [now, key]
                )
                return false
            }
            // First sighting (or the prior one expired): record/refresh and admit.
            try db.execute(
                sql: """
                INSERT INTO \(Table.dedupSeen) (key, last_seen_at) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET last_seen_at = excluded.last_seen_at
                """,
                arguments: [key, now]
            )
            return true
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
    public func latestPositionFixes() async throws -> [Int64: PositionFixRecord] {
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
