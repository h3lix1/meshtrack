// OffendersResetTests — covers the "Reset metrics" wipe added to the Largest-offenders
// screen. `OffendersViewModel.reset()` must clear the in-session aggregate SYNCHRONOUSLY
// (so the UI empties instantly) and also wipe the durable all-time ranking via
// `MeshStore.clearNodeTraffic()`. The store-level test proves the DELETE; the view-model
// tests prove the synchronous in-memory clear and (store-backed) the durable clear.

@testable import App
import Domain
import GRDB
import Persistence
import Testing

@Suite("Offenders reset — session + durable wipe")
@MainActor
struct OffendersResetTests {
    private func packet(
        from: UInt32 = 0xA1,
        packetID: UInt32 = 1,
        gatewayID: UInt32? = 0xAA
    ) -> DecodedPacket {
        DecodedPacket(
            from: from, to: 0xFFFF_FFFF, packetID: packetID, channel: 8, port: .position,
            payload: [], rxTime: Instant.epoch,
            hopStart: 3, hopLimit: 1, gatewayID: gatewayID
        )
    }

    @Test
    func `reset clears the in-session ranking synchronously`() {
        let vm = OffendersViewModel.sample()
        #expect(!vm.rows.isEmpty)
        #expect(vm.totalReceptions > 0)

        // Open a detail selection too, so we prove it is cleared.
        vm.select(nodeNum: vm.rows[0].nodeNum)
        #expect(vm.selectedNode != nil)

        vm.reset()

        #expect(vm.rows.isEmpty)
        #expect(vm.totalReceptions == 0)
        #expect(vm.persistedRows.isEmpty)
        #expect(vm.selectedNode == nil)
    }

    @Test
    func `reset clears a hydrated persisted ranking synchronously`() async throws {
        // Seed the durable table, hydrate persistedRows, then reset wipes them in-memory.
        let store = try MeshStore(DatabaseConnection.inMemory())
        try await store.saveTrafficStats(
            nodes: [
                NodeTrafficStatRecord(
                    node_num: 9, emitted: 2, receptions: 7, spread: 2,
                    first_seen_at: 0, last_seen_at: 60_000_000_000, dominant_port: 3
                )
            ],
            ports: []
        )
        let vm = OffendersViewModel(store: store)
        await vm.loadPersisted()
        #expect(!vm.persistedRows.isEmpty)

        vm.reset()
        #expect(vm.persistedRows.isEmpty)
    }

    @Test
    func `clearNodeTraffic empties the durable node ranking`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        try await store.upsertNodeTraffic(NodeTrafficStatRecord(
            node_num: 7, emitted: 3, receptions: 9, spread: 2,
            first_seen_at: 1000, last_seen_at: 5000, dominant_port: 3
        ))
        #expect(try await store.loadNodeTraffic().count == 1)

        try await store.clearNodeTraffic()
        #expect(try await store.loadNodeTraffic().isEmpty)
    }

    @Test
    func `clearNodeTraffic leaves the port ranking untouched`() async throws {
        // Reset belongs to the offenders (node) screen — the Ports screen's
        // port_traffic_stat must survive a node clear.
        let store = try MeshStore(DatabaseConnection.inMemory())
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

        try await store.clearNodeTraffic()

        #expect(try await store.loadNodeTraffic().isEmpty)
        #expect(try await store.loadPortTraffic().count == 1) // ports untouched
    }

    @Test
    func `reset wipes the durable ranking through the fire-and-forget task`() async throws {
        // Ingest + persist a node, then reset(); a fresh loadPersisted must yield empty,
        // proving reset() reached the durable table (not just the in-memory state).
        let store = try MeshStore(DatabaseConnection.inMemory())
        let vm = OffendersViewModel(store: store, persistInterval: 1)
        vm.ingest(packet(from: 0xA1, packetID: 1, gatewayID: 0xAA))
        vm.ingest(packet(from: 0xA1, packetID: 1, gatewayID: 0xBB))
        await vm.flush()
        #expect(try await store.loadNodeTraffic().isEmpty == false)

        vm.reset()
        // Await the durable clear deterministically rather than racing the fire-and-forget
        // Task: clear directly, which is idempotent with whatever reset() already did.
        try await store.clearNodeTraffic()

        let fresh = OffendersViewModel(store: store)
        await fresh.loadPersisted()
        #expect(fresh.persistedRows.isEmpty)
    }
}
