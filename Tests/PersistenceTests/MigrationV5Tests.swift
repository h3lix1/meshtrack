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

        // Apply UP TO v5 (its job is the dedupe-collapse + unique indexes; v6 then
        // supersedes the permanent indexes with a bounded ledger — see below).
        try MeshtrackMigrator.makeMigrator().migrate(queue, upTo: "v5")

        // The duplicate rows were collapsed to one per natural key …
        let counts = try await queue.read { db in
            try (
                message: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? -1,
                telemetry: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM telemetry") ?? -1,
                position: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM position_fix") ?? -1
            )
        }
        #expect(counts.message == 1)
        #expect(counts.telemetry == 1)
        #expect(counts.position == 1)

        // … and at v5 the unique indexes exist.
        let indexes = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        #expect(indexes.contains("idx_message_packet_from"))
        #expect(indexes.contains("idx_telemetry_natural_key"))
        #expect(indexes.contains("idx_position_fix_natural_key"))
    }

    @Test
    func `v6 drops the v5 unique indexes and adds the dedup ledger (Finding 5)`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory()) // full migrator → v6
        let names = try await store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('index','table')")
        }
        // The permanent unique indexes are gone …
        #expect(!names.contains("idx_message_packet_from"))
        #expect(!names.contains("idx_telemetry_natural_key"))
        #expect(!names.contains("idx_position_fix_natural_key"))
        // … the v1 non-unique query indexes remain …
        #expect(names.contains("idx_message_channel_time"))
        #expect(names.contains("idx_telemetry_node_time"))
        #expect(names.contains("idx_position_fix_node_time"))
        // … and the bounded ledger table now exists.
        #expect(names.contains("dedup_seen"))
    }

    @Test
    func `without an admit gate, the store no longer drops a later same-key row (Finding 5)`(
    ) async throws {
        // The v5 permanent unique index dropped EVERY future row sharing the coarse
        // key forever; v6 removes that. A direct second insert of the same natural
        // key now succeeds — windowed dedup is the pipeline's job via admitExtraction.
        let store = try MeshStore(DatabaseConnection.inMemory())
        let first = try await store.recordMessage(MessageRecord(
            packet_id: 1, from_num: 7, to_num: 0, channel: 8, body: "hi", rx_time: 100
        ))
        let second = try await store.recordMessage(MessageRecord(
            packet_id: 1, from_num: 7, to_num: 0, channel: 8, body: "hi", rx_time: 100
        ))
        #expect(first > 0)
        #expect(second > 0) // NOT dropped — both rows recorded
        #expect(try await store.recentMessages().count == 2)
    }
}
