import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@Suite("Migration v4 — app_config key-value table")
struct MigrationV4Tests {
    /// Build a database with v1…v3 applied (the pre-v4 world), then assert v4
    /// applies cleanly on top and the new table round-trips.
    private func makeV3Database() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        // Migrate up to (and including) v3 only — the pre-v4 world.
        try MeshtrackMigrator.makeMigrator().migrate(queue, upTo: "v3")
        return queue
    }

    @Test
    func `v4 applies cleanly over a v3 database and adds the app_config table`() async throws {
        let queue = try makeV3Database()
        // Seed a pre-v4 node so the migration runs against a populated db.
        try await queue.write { db in
            try db.execute(sql: """
            INSERT INTO node (node_num, node_class, first_seen_at, last_heard_at)
            VALUES (7, 'unknown', 100, 100)
            """)
        }

        // app_config does not exist yet.
        let before = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(!before.contains(Table.appConfig))

        // Apply the full migrator (now including v4).
        try MeshtrackMigrator.makeMigrator().migrate(queue)

        // New table exists with a TEXT primary key + NOT NULL value.
        let after = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(after.contains(Table.appConfig))

        // The schema declares a TEXT primary key on `key` and a NOT NULL `value`.
        let ddl: String? = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
                arguments: [Table.appConfig]
            )
        }
        let schema = ddl ?? ""
        #expect(schema.contains("PRIMARY KEY"))
        #expect(schema.contains("NOT NULL"))

        // Round-trip a row and confirm the primary key rejects duplicates.
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO \(Table.appConfig) (key, value) VALUES (?, ?)",
                arguments: ["broker", "{}"]
            )
        }
        let stored = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM \(Table.appConfig) WHERE key = ?",
                arguments: ["broker"]
            )
        }
        #expect(stored == "{}")

        // The pre-v4 node survived the migration untouched.
        let node = try await queue.read { db in try NodeRecord.fetchOne(db, key: 7) }
        #expect(node?.node_num == 7)
    }

    @Test
    func `a fresh in-memory store has the app_config table`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let tables = try await store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(tables.contains(Table.appConfig))
    }
}
