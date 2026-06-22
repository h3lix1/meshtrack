@testable import App
import Domain
import Persistence
import Testing

@Suite("Port + Offenders view models — ingest seam & persistence")
@MainActor
struct TrafficViewModelsTests {
    private func packet(
        from: UInt32 = 0xA1,
        packetID: UInt32 = 1,
        port: MeshPort = .position,
        gatewayID: UInt32? = 0xAA,
        at seconds: Double = 0
    ) -> DecodedPacket {
        DecodedPacket(
            from: from, to: 0xFFFF_FFFF, packetID: packetID, channel: 8, port: port,
            payload: [], rxTime: Instant.epoch.adding(seconds: seconds),
            hopStart: 3, hopLimit: 1, gatewayID: gatewayID
        )
    }

    @Test
    func `port view model projects rows and totals from the ingest seam`() {
        let vm = PortStatsViewModel()
        vm.ingest(packet(packetID: 1, port: .telemetry))
        vm.ingest(packet(packetID: 1, port: .telemetry, gatewayID: 0xBB)) // dup reception
        vm.ingest(packet(packetID: 2, port: .position))
        #expect(vm.totalReceptions == 3)
        #expect(vm.totalDistinctPackets == 2)
        #expect(vm.rows.first?.descriptor.name == "TELEMETRY_APP") // 2 receptions sorts first
        #expect(vm.channels.first?.channel == 8)
    }

    @Test
    func `offenders view model ranks nodes from the ingest seam`() {
        let vm = OffendersViewModel()
        vm.ingest(packet(from: 0xA1, packetID: 1, gatewayID: 0xAA))
        vm.ingest(packet(from: 0xA1, packetID: 1, gatewayID: 0xBB))
        vm.ingest(packet(from: 0xB2, packetID: 2, gatewayID: 0xAA))
        #expect(vm.rows.first?.nodeNum == 0xA1) // more receptions
        #expect(vm.rows.first?.receptions == 2)
    }

    @Test
    func `port view model persists and the offenders model re-loads the ranking`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let ports = PortStatsViewModel(store: store, persistInterval: 1000)
        let offenders = OffendersViewModel(store: store, persistInterval: 1000)
        for packet in TrafficSampleData.packets {
            ports.ingest(packet)
            offenders.ingest(packet)
        }
        await ports.flush()
        await offenders.flush()

        let portRows = try await store.loadPortTraffic()
        #expect(!portRows.isEmpty)
        let nodeRows = try await store.loadNodeTraffic()
        #expect(!nodeRows.isEmpty)

        // A fresh offenders model hydrates the all-time ranking from the durable table.
        let fresh = OffendersViewModel(store: store)
        await fresh.loadPersisted()
        #expect(!fresh.persistedRows.isEmpty)
        #expect(fresh.persistedRows.first?.receptions ?? 0 > 0)
    }

    @Test
    func `sample view models seed non-empty rows for previews`() {
        #expect(!PortStatsViewModel.sample().rows.isEmpty)
        #expect(!OffendersViewModel.sample().rows.isEmpty)
    }
}
