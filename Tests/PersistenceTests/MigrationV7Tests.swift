import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@Suite("Migration v7 — durable traffic-stats tables (Phase 10)")
struct MigrationV7Tests {
    @Test
    func `v7 creates the node + port traffic-stat tables`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let tables = try await store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(tables.contains(TrafficStatsTable.nodeTraffic))
        #expect(tables.contains(TrafficStatsTable.portTraffic))
    }

    @Test
    func `v7 indexes the offenders read column`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let indexes = try await store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        #expect(indexes.contains("idx_node_traffic_receptions"))
    }

    @Test
    func `the migration list registers v7 after v6`() {
        // A fresh migrator carries v7 in its applied-order set.
        let migrator = MeshtrackMigrator.makeMigrator()
        #expect(migrator.migrations.contains("v7"))
        #expect(migrator.migrations.last == "v7")
    }
}
