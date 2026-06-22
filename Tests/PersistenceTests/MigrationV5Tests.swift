import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@Suite("Migration v5 — idempotent extraction (unique natural-key indexes)")
struct MigrationV5Tests {
    /// Build a database with v1…v4 applied (the pre-v5 world) so we can prove v5
    /// is additive and dedupes any pre-existing duplicate extraction rows.
    private func makeV4Database() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try MeshtrackMigrator.makeMigrator().migrate(queue, upTo: "v4")
        return queue
    }

    @Test
    func `v5 dedupes pre-existing rows and adds the unique indexes`() async throws {
        let queue = try makeV4Database()
        // Seed pre-v5 DUPLICATE rows that the old (windowed) pipeline could create:
        // the same message/telemetry/position re-inserted via different gateways.
        try await queue.write { db in
            try db.execute(sql: """
            INSERT INTO message (packet_id, from_num, to_num, channel, body, rx_time)
            VALUES (42, 7, 0, 8, 'hello', 100), (42, 7, 0, 8, 'hello', 100)
            """)
            try db.execute(sql: """
            INSERT INTO telemetry (node_num, t, kind, key, value)
            VALUES (7, 100, 'device', 'battery_pct', 80),
                   (7, 100, 'device', 'battery_pct', 80)
            """)
            try db.execute(sql: """
            INSERT INTO position_fix (node_num, t, lat, lon)
            VALUES (7, 100, 37.7, -122.4), (7, 100, 37.7, -122.4)
            """)
        }

        // No unique index on the natural keys yet (pre-v5).
        let before = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        #expect(!before.contains("idx_message_packet_from"))

        // Apply the full migrator (now including v5).
        try MeshtrackMigrator.makeMigrator().migrate(queue)

        // The duplicate rows were collapsed to one per natural key …
        let counts = try await queue.read { db in
            (
                message: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? -1,
                telemetry: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM telemetry") ?? -1,
                position: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM position_fix") ?? -1
            )
        }
        #expect(counts.message == 1)
        #expect(counts.telemetry == 1)
        #expect(counts.position == 1)

        // … and the unique indexes now exist.
        let indexes = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        #expect(indexes.contains("idx_message_packet_from"))
        #expect(indexes.contains("idx_telemetry_natural_key"))
        #expect(indexes.contains("idx_position_fix_natural_key"))

        // The unique constraint now rejects a raw re-insert of the same natural key.
        await #expect(throws: DatabaseError.self) {
            try await queue.write { db in
                try db.execute(sql: """
                INSERT INTO message (packet_id, from_num, to_num, channel, body, rx_time)
                VALUES (42, 7, 0, 8, 'hello', 100)
                """)
            }
        }
    }

    @Test
    func `a fresh in-memory store has the v5 unique indexes`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let indexes = try await store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        #expect(indexes.contains("idx_message_packet_from"))
        #expect(indexes.contains("idx_telemetry_natural_key"))
        #expect(indexes.contains("idx_position_fix_natural_key"))
    }

    @Test
    func `store inserts are INSERT OR IGNORE on the natural key (idempotent)`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())

        // Two messages with the same (packet_id, from_num) → second is ignored.
        let first = try await store.recordMessage(MessageRecord(
            packet_id: 1, from_num: 7, to_num: 0, channel: 8, body: "hi", rx_time: 100
        ))
        let second = try await store.recordMessage(MessageRecord(
            packet_id: 1, from_num: 7, to_num: 0, channel: 8, body: "hi", rx_time: 100
        ))
        #expect(first > 0)
        #expect(second == 0) // ignored as a duplicate
        #expect(try await store.recentMessages().count == 1)

        // Telemetry idempotent on (node_num, t, kind, key).
        _ = try await store.appendTelemetry(
            TelemetryRecord(node_num: 7, t: 100, kind: .device, key: "battery_pct", value: 80)
        )
        let dupTelemetry = try await store.appendTelemetry(
            TelemetryRecord(node_num: 7, t: 100, kind: .device, key: "battery_pct", value: 80)
        )
        #expect(dupTelemetry == 0)
        #expect(try await store.telemetry(forNode: 7).count == 1)

        // Position idempotent on (node_num, t).
        _ = try await store.appendPositionFix(PositionFixRecord(node_num: 7, t: 100, lat: 1, lon: 2))
        let dupFix = try await store.appendPositionFix(
            PositionFixRecord(node_num: 7, t: 100, lat: 1, lon: 2)
        )
        #expect(dupFix == 0)
        #expect(try await store.positionFixes(forNode: 7).count == 1)
    }
}
