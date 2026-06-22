import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@Suite("Store+TrafficStats — upsert + query")
struct TrafficStatsStoreTests {
    private func makeStore() throws -> MeshStore {
        try MeshStore(DatabaseConnection.inMemory())
    }

    @Test
    func `node traffic upsert round-trips and overwrites running totals`() async throws {
        let store = try makeStore()
        try await store.upsertNodeTraffic(NodeTrafficStatRecord(
            node_num: 7, emitted: 3, receptions: 9, spread: 2,
            first_seen_at: 1000, last_seen_at: 5000, dominant_port: 3
        ))
        // A later snapshot carries larger running totals.
        try await store.upsertNodeTraffic(NodeTrafficStatRecord(
            node_num: 7, emitted: 5, receptions: 14, spread: 3,
            first_seen_at: 1000, last_seen_at: 8000, dominant_port: 67
        ))
        let rows = try await store.loadNodeTraffic()
        #expect(rows.count == 1)
        #expect(rows.first?.receptions == 14)
        #expect(rows.first?.emitted == 5)
        #expect(rows.first?.last_seen_at == 8000)
        #expect(rows.first?.dominant_port == 67)
    }

    @Test
    func `node upsert widens the observed window via MIN and MAX`() async throws {
        let store = try makeStore()
        try await store.upsertNodeTraffic(NodeTrafficStatRecord(
            node_num: 7, emitted: 1, receptions: 1, spread: 1,
            first_seen_at: 4000, last_seen_at: 6000, dominant_port: nil
        ))
        // An out-of-order snapshot with an earlier first / later last must widen, not clobber.
        try await store.upsertNodeTraffic(NodeTrafficStatRecord(
            node_num: 7, emitted: 2, receptions: 2, spread: 1,
            first_seen_at: 2000, last_seen_at: 9000, dominant_port: nil
        ))
        let row = try await store.loadNodeTraffic().first
        #expect(row?.first_seen_at == 2000)
        #expect(row?.last_seen_at == 9000)
    }

    @Test
    func `port traffic upsert round-trips and max_hops only grows`() async throws {
        let store = try makeStore()
        try await store.upsertPortTraffic(PortTrafficStatRecord(
            port: 67, receptions: 10, distinct_packets: 4, source_nodes: 2, gateways: 3, max_hops: 5
        ))
        // A later snapshot with FEWER hops must not shrink max_hops.
        try await store.upsertPortTraffic(PortTrafficStatRecord(
            port: 67, receptions: 20, distinct_packets: 8, source_nodes: 3, gateways: 4, max_hops: 2
        ))
        let row = try await store.loadPortTraffic().first
        #expect(row?.receptions == 20)
        #expect(row?.gateways == 4)
        #expect(row?.max_hops == 5) // kept the larger
    }

    @Test
    func `loadNodeTraffic returns worst offenders first`() async throws {
        let store = try makeStore()
        try await store.upsertNodeTraffic(NodeTrafficStatRecord(
            node_num: 1, emitted: 1, receptions: 3, spread: 1,
            first_seen_at: 0, last_seen_at: 1, dominant_port: nil
        ))
        try await store.upsertNodeTraffic(NodeTrafficStatRecord(
            node_num: 2, emitted: 1, receptions: 50, spread: 1,
            first_seen_at: 0, last_seen_at: 1, dominant_port: nil
        ))
        let rows = try await store.loadNodeTraffic()
        #expect(rows.map(\.node_num) == [2, 1]) // 50 receptions before 3
    }

    @Test
    func `bulk saveTrafficStats writes nodes and ports in one transaction`() async throws {
        let store = try makeStore()
        try await store.saveTrafficStats(
            nodes: [
                NodeTrafficStatRecord(
                    node_num: 1, emitted: 1, receptions: 5, spread: 1,
                    first_seen_at: 0, last_seen_at: 1, dominant_port: 3
                )
            ],
            ports: [
                PortTrafficStatRecord(
                    port: 3, receptions: 5, distinct_packets: 1, source_nodes: 1, gateways: 1, max_hops: 2
                )
            ]
        )
        #expect(try await store.loadNodeTraffic().count == 1)
        #expect(try await store.loadPortTraffic().count == 1)
    }
}
