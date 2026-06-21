import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@Suite("Migration v3 — node ownership, messages, ingest latency")
struct MigrationV3Tests {
    /// Build a database with ONLY v1 + v2 applied (the pre-v3 world), then assert
    /// v3 applies cleanly on top and the new columns/tables round-trip.
    private func makeV2Database() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        // Migrate up to (and including) v2 only — the pre-v3 world.
        try MeshtrackMigrator.makeMigrator().migrate(queue, upTo: "v2")
        return queue
    }

    @Test
    func `v3 applies cleanly over a v2 database and adds the new schema`() async throws {
        let queue = try makeV2Database()
        // Seed a pre-v3 node + observation so the ALTER touches real rows.
        try await queue.write { db in
            try db.execute(sql: """
            INSERT INTO node (node_num, node_class, first_seen_at, last_heard_at)
            VALUES (7, 'unknown', 100, 100)
            """)
            try db.execute(sql: """
            INSERT INTO observation (node_num, packet_id, transport, rx_time)
            VALUES (7, 1, 'mqtt', 100)
            """)
        }

        // Apply the full migrator (now including v3).
        try MeshtrackMigrator.makeMigrator().migrate(queue)

        // New table exists.
        let tables = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(tables.contains(Table.message))

        // Indexes exist.
        let indexes = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        #expect(indexes.contains("idx_message_channel_time"))
        #expect(indexes.contains("idx_message_time"))

        // Back-filled defaults: pre-v3 node is neither mine nor managed.
        let node = try await queue.read { db in try NodeRecord.fetchOne(db, key: 7) }
        #expect(node?.is_mine == false)
        #expect(node?.is_managed == false)

        // Pre-v3 observation has a null ingest_time (latency unknown).
        let ingest = try await queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT ingest_time FROM observation WHERE node_num = 7")
        }
        #expect(ingest == nil)
    }

    @Test
    func `ownership flags round-trip via the store helpers`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        try await store.upsertNode(NodeRecord(node_num: 7, first_seen_at: 1, last_heard_at: 1))
        try await store.upsertNode(NodeRecord(node_num: 8, first_seen_at: 1, last_heard_at: 2))

        #expect(try await store.isManaged(nodeNum: 7) == false)

        try await store.setOwnership(nodeNum: 7, isMine: true, isManaged: true)
        let node7 = try await store.fetchNode(nodeNum: 7)
        #expect(node7?.is_mine == true)
        #expect(node7?.is_managed == true)
        #expect(try await store.isManaged(nodeNum: 7) == true)

        // Partial update leaves the other flag intact.
        try await store.setOwnership(nodeNum: 7, isManaged: false)
        let node7b = try await store.fetchNode(nodeNum: 7)
        #expect(node7b?.is_mine == true) // unchanged
        #expect(node7b?.is_managed == false)

        // Bulk classify.
        let count = try await store.setOwnership(nodeNums: [7, 8, 999], isMine: true)
        #expect(count == 2) // 999 does not exist
        #expect(try await store.myNodes().map(\.node_num).sorted() == [7, 8])
        #expect(try await store.managedNodeNums().isEmpty)
    }

    @Test
    func `setOwnership on an unknown node throws nodeNotFound`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        await #expect(throws: StoreError.self) {
            try await store.setOwnership(nodeNum: 404, isMine: true)
        }
    }

    @Test
    func `observation ingest_time round-trips for latency`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let id = try await store.recordObservation(ObservationRecord(
            node_num: 7, packet_id: 1, transport: .mqtt, gateway_id: "!gw1",
            rx_time: 1000, ingest_time: 1500
        ))
        #expect(id > 0)
        let stored = try await store.writer.read { db in
            try ObservationRecord.fetchOne(db, key: id)
        }
        #expect(stored?.rx_time == 1000)
        #expect(stored?.ingest_time == 1500)
    }

    @Test
    func `messages insert and read back per-channel oldest-first and recent newest-first`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        try await store.recordMessage(MessageRecord(
            packet_id: 1, from_num: 7, to_num: 0xFFFF_FFFF, channel: 8,
            channel_name: "MediumFast", body: "hello", rx_time: 100
        ))
        try await store.recordMessage(MessageRecord(
            packet_id: 2, from_num: 8, to_num: 0xFFFF_FFFF, channel: 8,
            channel_name: "MediumFast", body: "world", rx_time: 200
        ))
        try await store.recordMessage(MessageRecord(
            packet_id: 3, from_num: 9, to_num: 7, channel: 0,
            body: "dm", rx_time: 150, is_dm: true
        ))

        let onChannel8 = try await store.messages(channel: 8)
        #expect(onChannel8.map(\.body) == ["hello", "world"]) // oldest-first

        let recent = try await store.recentMessages()
        #expect(recent.map(\.body) == ["world", "dm", "hello"]) // newest-first
        #expect(recent.first(where: { $0.is_dm })?.body == "dm")
    }
}
