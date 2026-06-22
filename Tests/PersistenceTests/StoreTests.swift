import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@Suite("MeshStore + schema v1")
struct StoreTests {
    private func makeStore() throws -> MeshStore {
        try MeshStore(DatabaseConnection.inMemory())
    }

    @Test
    func `migration v1 creates every schema table`() async throws {
        let store = try makeStore()
        let tables = try await store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        let expected = [
            Table.node, Table.nodeConfig, Table.observation, Table.positionFix,
            Table.telemetry, Table.arming, Table.alertRule, Table.alert, Table.template
        ]
        for name in expected {
            #expect(tables.contains(name), "missing table \(name)")
        }
    }

    @Test
    func `node upsert round-trips and updates in place`() async throws {
        let store = try makeStore()
        try await store.upsertNode(NodeRecord(
            node_num: 4242,
            hexid: "!00001092",
            short_name: "BASE",
            node_class: .fixed,
            first_seen_at: 1000,
            last_heard_at: 1000
        ))
        let fetched = try await store.fetchNode(nodeNum: 4242)
        #expect(fetched?.short_name == "BASE")
        #expect(fetched?.node_class == .fixed)

        try await store.upsertNode(NodeRecord(
            node_num: 4242,
            hexid: "!00001092",
            short_name: "BASE2",
            node_class: .fixed,
            first_seen_at: 1000,
            last_heard_at: 2000
        ))
        let updated = try await store.fetchNode(nodeNum: 4242)
        #expect(updated?.short_name == "BASE2")
        #expect(updated?.last_heard_at == 2000)
    }

    @Test
    func `markHeard creates then advances last_heard_at, preserving first_seen_at`() async throws {
        let store = try makeStore()
        try await store.markHeard(nodeNum: 7, at: Instant(nanosecondsSinceEpoch: 500))
        let created = try await store.fetchNode(nodeNum: 7)
        #expect(created?.first_seen_at == 500)
        #expect(created?.last_heard_at == 500)

        try await store.markHeard(nodeNum: 7, at: Instant(nanosecondsSinceEpoch: 900))
        let bumped = try await store.fetchNode(nodeNum: 7)
        #expect(bumped?.first_seen_at == 500)
        #expect(bumped?.last_heard_at == 900)
    }

    @Test
    func `observations are append-only provenance; only exact re-delivery is rejected`() async throws {
        let store = try makeStore()
        let obs = ObservationRecord(
            node_num: 7, packet_id: 0xDEAD_BEEF, transport: .mqtt,
            gateway_id: "!gw1", rx_time: 1000, rx_rssi: -90, rx_snr: 5.5
        )
        let id = try await store.recordObservation(obs)
        #expect(id > 0)

        // Exact re-delivery (same packet + node + gateway + transport) is rejected — idempotent.
        await #expect(throws: StoreError.self) {
            try await store.recordObservation(obs)
        }

        // The SAME packet via a DIFFERENT gateway is valid provenance (SPEC §2.4) — kept.
        var viaOtherGateway = obs
        viaOtherGateway.gateway_id = "!gw2"
        let id2 = try await store.recordObservation(viaOtherGateway)
        #expect(id2 > 0)

        // A different node with the same packet_id is allowed.
        var otherNode = obs
        otherNode.node_num = 8
        let id3 = try await store.recordObservation(otherNode)
        #expect(id3 > 0)
    }

    @Test
    func `telemetry appends and reads back ordered by time`() async throws {
        let store = try makeStore()
        try await store.appendTelemetry(TelemetryRecord(
            node_num: 7,
            t: 300,
            kind: .device,
            key: "battery_pct",
            value: 80
        ))
        try await store.appendTelemetry(TelemetryRecord(
            node_num: 7,
            t: 100,
            kind: .device,
            key: "battery_pct",
            value: 95
        ))
        try await store.appendTelemetry(TelemetryRecord(
            node_num: 7,
            t: 200,
            kind: .environment,
            key: "temp",
            value: 21.5
        ))

        let series = try await store.telemetry(forNode: 7)
        #expect(series.map(\.t) == [100, 200, 300])
        #expect(series.first?.value == 95)
    }

    @Test
    func `position fixes append and read back ordered by time`() async throws {
        let store = try makeStore()
        try await store.appendPositionFix(PositionFixRecord(
            node_num: 7,
            t: 20,
            lat: 37.77,
            lon: -122.41,
            h_accuracy: 5
        ))
        try await store.appendPositionFix(PositionFixRecord(
            node_num: 7,
            t: 10,
            lat: 37.76,
            lon: -122.40,
            h_accuracy: 8
        ))
        let fixes = try await store.positionFixes(forNode: 7)
        #expect(fixes.map(\.t) == [10, 20])
    }

    @Test
    func `latestPositionFixes returns the newest fix per node in one query`() async throws {
        let store = try makeStore()
        // Node 7: two fixes — the later `t` must win.
        try await store.appendPositionFix(PositionFixRecord(node_num: 7, t: 10, lat: 1.0, lon: 1.0))
        try await store.appendPositionFix(PositionFixRecord(node_num: 7, t: 20, lat: 2.0, lon: 2.0))
        // Node 9: a single fix.
        try await store.appendPositionFix(PositionFixRecord(node_num: 9, t: 5, lat: 3.0, lon: 3.0))

        let latest = try await store.latestPositionFixes()
        #expect(latest.count == 2)
        #expect(latest[7]?.t == 20)
        #expect(latest[7]?.lat == 2.0)
        #expect(latest[9]?.t == 5)
        // A node with no fix simply isn't present (the live view ignores it).
        #expect(latest[42] == nil)
    }

    @Test
    func `latestPositionFixes breaks t ties by the later-inserted fix`() async throws {
        let store = try makeStore()
        // Two fixes at the SAME instant: the batched query must keep the later-inserted
        // one, matching loadNodes()'s old `max(by: { $0.t < $1.t })` tie-break.
        try await store.appendPositionFix(PositionFixRecord(node_num: 7, t: 10, lat: 1.0, lon: 1.0))
        try await store.appendPositionFix(PositionFixRecord(node_num: 7, t: 10, lat: 9.0, lon: 9.0))

        let latest = try await store.latestPositionFixes()
        #expect(latest[7]?.lat == 9.0)
    }

    @Test
    func `latestPositionFixes is empty when no node has a fix`() async throws {
        let store = try makeStore()
        let latest = try await store.latestPositionFixes()
        #expect(latest.isEmpty)
    }

    @Test
    func `on-disk database is opened in WAL mode`() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("meshtrack-test-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let pool = try DatabaseConnection.onDisk(path: path)
        let mode = try await pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        #expect(mode?.lowercased() == "wal")
    }
}
