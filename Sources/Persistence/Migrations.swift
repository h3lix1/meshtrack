// Migration framework + schema v1 (SPEC §5).
//
// Migrations are append-only and identified by a stable name. Schema v1 creates
// every table and the indexes that make the time-series and dedup queries cheap.
// Each table lives in its own builder to keep the migration flat and readable.

import GRDB

public enum MeshtrackMigrator {
    /// The migrator carrying every schema version. Apply with `migrate(_:)`.
    public static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try createNode(db)
            try createNodeConfig(db)
            try createObservation(db)
            try createPositionFix(db)
            try createTelemetry(db)
            try createArming(db)
            try createAlertRule(db)
            try createAlert(db)
            try createTemplate(db)
        }
        migrator.registerMigration("v2") { db in
            try createTelemetryRollup(db, named: Table.telemetryHourly)
            try createTelemetryRollup(db, named: Table.telemetryDaily)
        }
        // Phase 7: node ownership (ADR 0008), monitor-only messaging (ADR 0006),
        // and reception→publish latency provenance (SPEC §2.11).
        migrator.registerMigration("v3") { db in
            try addNodeOwnership(db)
            try addObservationIngestTime(db)
            try createMessage(db)
        }
        // Phase 8: configuration moves out of env vars into the shared store
        // (SPEC §2.5/§10). App config (broker connection, app settings) is
        // JSON-encoded into a simple key-value table; the broker password and
        // channel PSKs live in the same table (`CredentialStore` / `KeyStore`).
        migrator.registerMigration("v4") { db in
            try createAppConfig(db)
        }
        // Phase 8 hardening: make app-payload extraction idempotent at the STORE
        // layer (Finding 2). The pipeline's in-memory `DedupWindow` is recreated
        // every `run()` (per reconnect/config change) and observation dedup is
        // gateway-scoped, so a packet re-delivered via a different gateway after a
        // reconnect could insert a duplicate message/telemetry/position row. A
        // unique index on each table's natural key — combined with `INSERT OR
        // IGNORE` in the store — makes "count once" durable across process/run
        // boundaries rather than relying on the volatile window.
        migrator.registerMigration("v5") { db in
            try dedupeExtractionTables(db)
            try addExtractionUniqueIndexes(db)
        }
        // Phase 9 (Finding 5): the v5 PERMANENT unique indexes silently drop EVERY
        // future row sharing a coarse natural key forever — violating the SPEC §2.4
        // sliding-window dedup contract. Legitimate packet-id reuse after the 600s
        // window, or two genuinely-distinct fixes/samples that happen to share the
        // coarse key, are lost permanently. v6 replaces the permanent index with a
        // BOUNDED, window-correct dedup ledger: drop the unique indexes (the v1
        // non-unique query indexes already cover reads) and add `dedup_seen`, a
        // small last-seen ledger consulted against the 600s window. Cross-run/reconnect
        // idempotency is preserved; expiry lets a key recur after the window.
        migrator.registerMigration("v6") { db in
            try dropExtractionUniqueIndexes(db)
            try createDedupSeen(db)
        }
        // Phase 10 (items 11–13): durable per-node / per-port mesh-traffic counters
        // backing the Port-numbers + Largest-offenders analytics screens, so the
        // offenders ranking survives across sessions. The builder lives in its own
        // file (`Migrations+TrafficStats.swift`); appended here, never editing v1–v6.
        registerTrafficStats(&migrator)
        return migrator
    }

    /// `app_config` — key-value store for non-secret app configuration (Phase 8).
    /// `ConfigGateway` JSON-encodes `BrokerConfig`/`AppSettings` into rows under
    /// stable keys (`"broker"`, `"app_settings"`). Never holds secrets — the DB
    /// must never store plaintext secrets (SPEC §2.5).
    private static func createAppConfig(_ db: Database) throws {
        try db.create(table: Table.appConfig) { t in
            t.primaryKey("key", .text)
            t.column("value", .text).notNull()
        }
    }

    /// `node` ownership flags (ADR 0008). `is_mine` drives the "My Nodes" filter
    /// (visibility); `is_managed` gates ownership-sensitive rules (battery/voltage/
    /// stale). Both default false so pre-v3 rows stay unmanaged/unowned.
    private static func addNodeOwnership(_ db: Database) throws {
        try db.alter(table: Table.node) { t in
            t.add(column: "is_mine", .boolean).notNull().defaults(to: false)
            t.add(column: "is_managed", .boolean).notNull().defaults(to: false)
        }
    }

    /// `observation.ingest_time` — our `Clock` wall-clock at frame receipt
    /// (SPEC §2.11). Nullable for back-compat: pre-v3 rows have no ingest time, so
    /// latency (`ingest_time − rx_time`) is simply unknown for them.
    private static func addObservationIngestTime(_ db: Database) throws {
        try db.alter(table: Table.observation) { t in
            t.add(column: "ingest_time", .integer)
        }
    }

    /// `message` — decoded `TEXT_MESSAGE_APP` payloads for the read-only Channels
    /// view (ADR 0006). Append-only; the pipeline counts once per dedup key like
    /// telemetry/position. Indexed for per-channel and recency queries.
    private static func createMessage(_ db: Database) throws {
        try db.create(table: Table.message) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("packet_id", .integer).notNull()
            t.column("from_num", .integer).notNull()
            t.column("to_num", .integer).notNull()
            t.column("channel", .integer).notNull()
            t.column("channel_name", .text)
            t.column("body", .text).notNull()
            t.column("rx_time", .integer).notNull()
            t.column("is_dm", .boolean).notNull().defaults(to: false)
        }
        try db.create(
            index: "idx_message_channel_time",
            on: Table.message,
            columns: ["channel", "rx_time"]
        )
        try db.create(index: "idx_message_time", on: Table.message, columns: ["rx_time"])
    }

    /// Downsampled telemetry rollup table (hourly/daily): one row per
    /// (node, bucket, kind, key) with min/max/avg/count (SPEC §5 retention).
    private static func createTelemetryRollup(_ db: Database, named table: String) throws {
        try db.create(table: table) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("node_num", .integer).notNull()
            t.column("bucket", .integer).notNull() // bucket-start, ns since epoch
            t.column("kind", .text).notNull()
            t.column("key", .text).notNull()
            t.column("min_value", .double).notNull()
            t.column("max_value", .double).notNull()
            t.column("avg_value", .double).notNull()
            t.column("sample_count", .integer).notNull()
        }
        try db.create(
            index: "idx_\(table)_bucket",
            on: table,
            columns: ["node_num", "bucket", "kind", "key"],
            options: [.unique]
        )
    }

    private static func createNode(_ db: Database) throws {
        try db.create(table: Table.node) { t in
            t.primaryKey("node_num", .integer)
            t.column("hexid", .text)
            t.column("short_name", .text)
            t.column("long_name", .text)
            t.column("node_class", .text).notNull().defaults(to: NodeClass.unknown.rawValue)
            t.column("hw_model", .text)
            t.column("role", .text)
            t.column("first_seen_at", .integer).notNull()
            t.column("last_heard_at", .integer).notNull()
        }
    }

    private static func createNodeConfig(_ db: Database) throws {
        try db.create(table: Table.nodeConfig) { t in
            t.primaryKey("node_num", .integer).references(Table.node, onDelete: .cascade)
            t.column("region", .text)
            t.column("channels_json", .text)
            t.column("position_precision", .integer)
            t.column("mqtt_json", .text)
        }
    }

    private static func createObservation(_ db: Database) throws {
        try db.create(table: Table.observation) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("node_num", .integer).notNull()
            t.column("packet_id", .integer).notNull()
            t.column("transport", .text).notNull()
            t.column("gateway_id", .text)
            t.column("rx_time", .integer).notNull()
            t.column("rx_rssi", .integer)
            t.column("rx_snr", .double)
            t.column("hop_start", .integer)
            t.column("hop_limit", .integer)
        }
        // Observations are append-only provenance (SPEC §2.4): the same packet may
        // arrive via several gateways, each its own row. Only an EXACT re-delivery
        // (same packet + node + gateway + transport) is rejected, for idempotency on
        // backfill/reconnect. Telemetry/position "count once" is the pipeline's
        // DedupWindow, not this index.
        try db.create(
            index: "idx_observation_provenance",
            on: Table.observation,
            columns: ["packet_id", "node_num", "gateway_id", "transport"],
            options: [.unique]
        )
        try db.create(
            index: "idx_observation_node_time",
            on: Table.observation,
            columns: ["node_num", "rx_time"]
        )
    }

    private static func createPositionFix(_ db: Database) throws {
        try db.create(table: Table.positionFix) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("node_num", .integer).notNull()
            t.column("t", .integer).notNull()
            t.column("lat", .double).notNull()
            t.column("lon", .double).notNull()
            t.column("alt", .double)
            t.column("sats", .integer)
            t.column("h_accuracy", .double)
            t.column("precision_bits", .integer)
        }
        try db.create(
            index: "idx_position_fix_node_time",
            on: Table.positionFix,
            columns: ["node_num", "t"]
        )
    }

    private static func createTelemetry(_ db: Database) throws {
        try db.create(table: Table.telemetry) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("node_num", .integer).notNull()
            t.column("t", .integer).notNull()
            t.column("kind", .text).notNull()
            t.column("key", .text).notNull()
            t.column("value", .double).notNull()
        }
        try db.create(index: "idx_telemetry_node_time", on: Table.telemetry, columns: ["node_num", "t"])
        try db.create(
            index: "idx_telemetry_node_key_time",
            on: Table.telemetry,
            columns: ["node_num", "key", "t"]
        )
    }

    private static func createArming(_ db: Database) throws {
        try db.create(table: Table.arming) { t in
            t.primaryKey("node_num", .integer).references(Table.node, onDelete: .cascade)
            t.column("armed", .boolean).notNull().defaults(to: false)
            t.column("threshold_m", .double).notNull()
            t.column("anchor_lat", .double)
            t.column("anchor_lon", .double)
            t.column("anchor_accuracy", .double)
            t.column("captured_at", .integer)
            t.column("state", .text).notNull().defaults(to: ArmingState.anchored.rawValue)
        }
    }

    private static func createAlertRule(_ db: Database) throws {
        try db.create(table: Table.alertRule) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("scope", .text).notNull()
            t.column("scope_id", .text)
            t.column("type", .text).notNull()
            t.column("params_json", .text)
            t.column("enabled", .boolean).notNull().defaults(to: true)
        }
    }

    private static func createAlert(_ db: Database) throws {
        try db.create(table: Table.alert) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("rule_id", .integer).references(Table.alertRule, onDelete: .setNull)
            t.column("node_num", .integer).notNull()
            t.column("type", .text).notNull()
            t.column("state", .text).notNull().defaults(to: AlertState.firing.rawValue)
            t.column("fired_at", .integer).notNull()
            t.column("acked_at", .integer)
            t.column("resolved_at", .integer)
            t.column("payload_json", .text)
        }
        try db.create(index: "idx_alert_node_state", on: Table.alert, columns: ["node_num", "state"])
    }

    private static func createTemplate(_ db: Database) throws {
        try db.create(table: Table.template) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull()
            t.column("dsl", .text).notNull()
            t.column("region", .text).notNull()
            t.column("role", .text)
            t.column("config_json", .text)
            t.column("firmware_variant", .text)
        }
    }
}

// MARK: - v5 idempotent-extraction helpers (Phase 8, Finding 2)

extension MeshtrackMigrator {
    /// Collapse any pre-v5 duplicate extraction rows down to one per natural key
    /// so the new unique indexes can be created without violating existing data.
    /// Keeps the lowest `id` (earliest insert) per group; deletes the rest. A
    /// fresh database has nothing to dedupe, so these run as cheap no-ops.
    static func dedupeExtractionTables(_ db: Database) throws {
        // message: one row per (packet_id, from_num) — the same logical message.
        try db.execute(sql: """
        DELETE FROM \(Table.message) WHERE id NOT IN (
            SELECT MIN(id) FROM \(Table.message) GROUP BY packet_id, from_num
        )
        """)
        // telemetry: one row per (node_num, t, kind, key) — one sample.
        try db.execute(sql: """
        DELETE FROM \(Table.telemetry) WHERE id NOT IN (
            SELECT MIN(id) FROM \(Table.telemetry) GROUP BY node_num, t, kind, key
        )
        """)
        // position_fix: one row per (node_num, t) — one fix at an instant.
        try db.execute(sql: """
        DELETE FROM \(Table.positionFix) WHERE id NOT IN (
            SELECT MIN(id) FROM \(Table.positionFix) GROUP BY node_num, t
        )
        """)
    }

    /// Unique indexes on the extraction tables' natural keys. With the store's
    /// `INSERT OR IGNORE`, a re-delivered packet (e.g. via a different gateway
    /// after a reconnect) is silently dropped instead of duplicating a row.
    static func addExtractionUniqueIndexes(_ db: Database) throws {
        try db.create(
            index: "idx_message_packet_from",
            on: Table.message,
            columns: ["packet_id", "from_num"],
            options: [.unique]
        )
        try db.create(
            index: "idx_telemetry_natural_key",
            on: Table.telemetry,
            columns: ["node_num", "t", "kind", "key"],
            options: [.unique]
        )
        try db.create(
            index: "idx_position_fix_natural_key",
            on: Table.positionFix,
            columns: ["node_num", "t"],
            options: [.unique]
        )
    }
}

// MARK: - v6 windowed-dedup ledger (Phase 9, Finding 5)

extension MeshtrackMigrator {
    /// Remove the v5 PERMANENT unique indexes. They enforced a coarse natural key
    /// for all time, so `INSERT OR IGNORE` dropped legitimate later rows (packet-id
    /// reuse past the window, or distinct samples/fixes that share the coarse key).
    /// The v1 non-unique indexes (`idx_message_channel_time`, `idx_telemetry_*`,
    /// `idx_position_fix_node_time`) already serve every read, so dropping these
    /// costs no query speed. `IF EXISTS` keeps the drop idempotent.
    static func dropExtractionUniqueIndexes(_ db: Database) throws {
        try db.execute(sql: "DROP INDEX IF EXISTS idx_message_packet_from")
        try db.execute(sql: "DROP INDEX IF EXISTS idx_telemetry_natural_key")
        try db.execute(sql: "DROP INDEX IF EXISTS idx_position_fix_natural_key")
    }

    /// `dedup_seen` — the bounded, window-correct extraction dedup ledger (SPEC
    /// §2.4). One row per packet identity (`<from>:<packet_id>`) carrying the last
    /// time we extracted it. The store admits an extraction only when the key is
    /// absent or last seen MORE than the dedup window ago, then records/slides the
    /// row and prunes expired keys — so a reconnect re-delivery within the window
    /// is deduped (durably, across `run()` boundaries the in-memory window cannot
    /// span) yet the same key recurring after the window records a fresh extraction.
    static func createDedupSeen(_ db: Database) throws {
        try db.create(table: Table.dedupSeen) { t in
            t.primaryKey("key", .text)
            t.column("last_seen_at", .integer).notNull()
        }
        // Bounded-size pruning deletes by age; index the time column for it.
        try db.create(
            index: "idx_dedup_seen_last_seen",
            on: Table.dedupSeen,
            columns: ["last_seen_at"]
        )
    }
}
