// Migrations+TrafficStats — the schema v7 migration for durable mesh-traffic
// counters (Phase 10, items 11–13). A NEW migration appended to the list in
// `MeshtrackMigrator.makeMigrator()`; it does not touch any existing migration.
// The builder lives here (an `extension MeshtrackMigrator`) so the new tables are
// described next to the records that back them (`Store+TrafficStats.swift`).

import GRDB

extension MeshtrackMigrator {
    /// Register the v7 traffic-stats migration onto an existing migrator. Called once
    /// from `makeMigrator()` after v6 so the append is explicit and ordered.
    static func registerTrafficStats(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v7") { db in
            try createNodeTrafficStat(db)
            try createPortTrafficStat(db)
        }
    }

    /// `node_traffic_stat` — durable per-node burden counters (the offenders source).
    /// Keyed by `node_num`; running totals upserted with ON CONFLICT accumulation.
    /// Indexed on `receptions` so the worst-offenders read is a cheap ordered scan.
    private static func createNodeTrafficStat(_ db: Database) throws {
        try db.create(table: TrafficStatsTable.nodeTraffic) { t in
            t.primaryKey("node_num", .integer)
            t.column("emitted", .integer).notNull().defaults(to: 0)
            t.column("receptions", .integer).notNull().defaults(to: 0)
            t.column("spread", .integer).notNull().defaults(to: 0)
            t.column("first_seen_at", .integer).notNull()
            t.column("last_seen_at", .integer).notNull()
            t.column("dominant_port", .integer)
        }
        try db.create(
            index: "idx_node_traffic_receptions",
            on: TrafficStatsTable.nodeTraffic,
            columns: ["receptions"]
        )
    }

    /// `port_traffic_stat` — durable per-port counters (the port-numbers source).
    /// Keyed by the raw `PortNum`; the table is tiny (one row per port in use).
    private static func createPortTrafficStat(_ db: Database) throws {
        try db.create(table: TrafficStatsTable.portTraffic) { t in
            t.primaryKey("port", .integer)
            t.column("receptions", .integer).notNull().defaults(to: 0)
            t.column("distinct_packets", .integer).notNull().defaults(to: 0)
            t.column("source_nodes", .integer).notNull().defaults(to: 0)
            t.column("gateways", .integer).notNull().defaults(to: 0)
            t.column("max_hops", .integer).notNull().defaults(to: 0)
        }
    }
}
