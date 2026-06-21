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
        return migrator
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
