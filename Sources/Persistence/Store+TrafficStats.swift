// Store+TrafficStats — durable per-node / per-port mesh-traffic counters (Phase 10,
// items 11–13). A same-module `extension MeshStore`: everything goes through the
// public `writer`, so this needs no special access into `Store.swift` (which stays
// untouched). The schema v7 migration that creates the backing tables lives in
// `Migrations+TrafficStats.swift`; the table names + record types live here so the
// whole feature is one self-contained persistence unit.
//
// WHY PERSIST: the live aggregators (`TrafficAggregator` in App) hold a session's
// counters in memory and die with the process. The offenders ranking is far more
// useful when it survives restarts, so the App view models snapshot their running
// aggregate through `upsertTrafficStats` on a slow cadence, and re-seed from
// `loadTrafficStats` on launch. Counters are MONOTONIC running totals keyed by the
// natural identity (`node_num` / `port`), upserted with ON CONFLICT accumulation.

import Domain
import GRDB

// swiftlint:disable identifier_name
// Justification: the record properties below mirror SQLite column names (snake_case,
// the database's convention) so GRDB's Codable maps them to columns with zero
// CodingKeys boilerplate — exactly as `Records.swift` does. Scoped to this file.

/// Traffic-stats table names (schema v7). Kept here (not in `Schema.swift`) so the
/// feature is self-contained; `Schema.swift` stays untouched.
public enum TrafficStatsTable {
    /// Per-node running traffic counters (the offenders ranking source).
    public static let nodeTraffic = "node_traffic_stat"
    /// Per-port running traffic counters (the port-numbers screen source).
    public static let portTraffic = "port_traffic_stat"
}

/// `node_traffic_stat` — one row per source node, carrying its accumulated burden.
public struct NodeTrafficStatRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = TrafficStatsTable.nodeTraffic

    public var node_num: Int64
    /// Distinct logical packets the node has originated.
    public var emitted: Int64
    /// Every reception attributed to the node (flood contribution).
    public var receptions: Int64
    /// Distinct gateways/locations that have heard it — spread across the mesh.
    public var spread: Int64
    /// First reception instant (ns since epoch) — the chattiness window start.
    public var first_seen_at: Int64
    /// Last reception instant (ns since epoch) — the chattiness window end.
    public var last_seen_at: Int64
    /// The node's dominant port raw value (most receptions), nullable.
    public var dominant_port: Int64?

    public init(
        node_num: Int64,
        emitted: Int64,
        receptions: Int64,
        spread: Int64,
        first_seen_at: Int64,
        last_seen_at: Int64,
        dominant_port: Int64?
    ) {
        self.node_num = node_num
        self.emitted = emitted
        self.receptions = receptions
        self.spread = spread
        self.first_seen_at = first_seen_at
        self.last_seen_at = last_seen_at
        self.dominant_port = dominant_port
    }
}

/// `port_traffic_stat` — one row per `PortNum`, carrying its accumulated stats.
public struct PortTrafficStatRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = TrafficStatsTable.portTraffic

    public var port: Int64
    public var receptions: Int64
    public var distinct_packets: Int64
    public var source_nodes: Int64
    public var gateways: Int64
    public var max_hops: Int64

    public init(
        port: Int64,
        receptions: Int64,
        distinct_packets: Int64,
        source_nodes: Int64,
        gateways: Int64,
        max_hops: Int64
    ) {
        self.port = port
        self.receptions = receptions
        self.distinct_packets = distinct_packets
        self.source_nodes = source_nodes
        self.gateways = gateways
        self.max_hops = max_hops
    }
}

public extension MeshStore {
    /// Upsert the per-node traffic counters. Receptions/emitted/spread ACCUMULATE
    /// (running totals); the window widens (`first_seen` = min, `last_seen` = max);
    /// the dominant port is overwritten with the freshest snapshot. Idempotent-ish:
    /// callers pass running totals, not deltas, so re-snapshotting the same aggregate
    /// is safe to read back — the latest write wins per column it overwrites.
    func upsertNodeTraffic(_ record: NodeTrafficStatRecord) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO \(TrafficStatsTable.nodeTraffic)
                    (node_num, emitted, receptions, spread, first_seen_at, last_seen_at, dominant_port)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(node_num) DO UPDATE SET
                    emitted = excluded.emitted,
                    receptions = excluded.receptions,
                    spread = excluded.spread,
                    first_seen_at = MIN(first_seen_at, excluded.first_seen_at),
                    last_seen_at = MAX(last_seen_at, excluded.last_seen_at),
                    dominant_port = excluded.dominant_port
                """,
                arguments: [
                    record.node_num, record.emitted, record.receptions, record.spread,
                    record.first_seen_at, record.last_seen_at, record.dominant_port
                ]
            )
        }
    }

    /// Upsert the per-port traffic counters. The snapshot wins per column (callers
    /// pass running totals), and `max_hops` takes the larger of stored vs incoming.
    func upsertPortTraffic(_ record: PortTrafficStatRecord) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO \(TrafficStatsTable.portTraffic)
                    (port, receptions, distinct_packets, source_nodes, gateways, max_hops)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(port) DO UPDATE SET
                    receptions = excluded.receptions,
                    distinct_packets = excluded.distinct_packets,
                    source_nodes = excluded.source_nodes,
                    gateways = excluded.gateways,
                    max_hops = MAX(max_hops, excluded.max_hops)
                """,
                arguments: [
                    record.port, record.receptions, record.distinct_packets,
                    record.source_nodes, record.gateways, record.max_hops
                ]
            )
        }
    }

    /// Bulk-upsert many node + port rows in ONE transaction (the snapshot path).
    func saveTrafficStats(
        nodes: [NodeTrafficStatRecord],
        ports: [PortTrafficStatRecord]
    ) async throws {
        try await writer.write { db in
            for record in nodes {
                try Self.upsertNode(record, into: db)
            }
            for record in ports {
                try Self.upsertPort(record, into: db)
            }
        }
    }

    /// Per-node traffic rows, worst offenders first (most receptions).
    func loadNodeTraffic(limit: Int = 100) async throws -> [NodeTrafficStatRecord] {
        try await writer.read { db in
            try NodeTrafficStatRecord
                .order(Column("receptions").desc, Column("emitted").desc, Column("node_num"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Per-port traffic rows, busiest port first (most receptions).
    func loadPortTraffic() async throws -> [PortTrafficStatRecord] {
        try await writer.read { db in
            try PortTrafficStatRecord
                .order(Column("receptions").desc, Column("port"))
                .fetchAll(db)
        }
    }

    /// Wipe the durable all-time node ranking (the offenders source) so it starts
    /// fresh. Scoped to `node_traffic_stat` ONLY — `port_traffic_stat` (the separate
    /// Ports screen) is left untouched.
    func clearNodeTraffic() async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM \(TrafficStatsTable.nodeTraffic)")
        }
    }

    // MARK: Shared single-row upserts (used by the bulk path)

    private static func upsertNode(_ record: NodeTrafficStatRecord, into db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO \(TrafficStatsTable.nodeTraffic)
                (node_num, emitted, receptions, spread, first_seen_at, last_seen_at, dominant_port)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(node_num) DO UPDATE SET
                emitted = excluded.emitted,
                receptions = excluded.receptions,
                spread = excluded.spread,
                first_seen_at = MIN(first_seen_at, excluded.first_seen_at),
                last_seen_at = MAX(last_seen_at, excluded.last_seen_at),
                dominant_port = excluded.dominant_port
            """,
            arguments: [
                record.node_num, record.emitted, record.receptions, record.spread,
                record.first_seen_at, record.last_seen_at, record.dominant_port
            ]
        )
    }

    private static func upsertPort(_ record: PortTrafficStatRecord, into db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO \(TrafficStatsTable.portTraffic)
                (port, receptions, distinct_packets, source_nodes, gateways, max_hops)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(port) DO UPDATE SET
                receptions = excluded.receptions,
                distinct_packets = excluded.distinct_packets,
                source_nodes = excluded.source_nodes,
                gateways = excluded.gateways,
                max_hops = MAX(max_hops, excluded.max_hops)
            """,
            arguments: [
                record.port, record.receptions, record.distinct_packets,
                record.source_nodes, record.gateways, record.max_hops
            ]
        )
    }
}

// swiftlint:enable identifier_name
