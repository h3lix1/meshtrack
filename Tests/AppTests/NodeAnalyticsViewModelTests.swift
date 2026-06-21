@testable import App
import Domain
import Persistence
import Testing

@Suite("NodeAnalyticsViewModel")
@MainActor
struct NodeAnalyticsViewModelTests {
    private let nodeNum: Int64 = 0xA1B2_C3D4

    private func observation(
        snr: Double? = nil,
        rssi: Int? = nil,
        hopStart: Int? = nil,
        hopLimit: Int? = nil,
        gateway: String? = nil,
        rxNanos: Int64 = 0
    ) -> ObservationRecord {
        ObservationRecord(
            node_num: nodeNum, packet_id: 1, transport: .mqtt, gateway_id: gateway,
            rx_time: rxNanos, rx_rssi: rssi, rx_snr: snr, hop_start: hopStart, hop_limit: hopLimit
        )
    }

    private func packet(port: MeshPort) -> DecodedPacket {
        DecodedPacket(
            from: UInt32(truncatingIfNeeded: nodeNum), to: 0xFFFF_FFFF, packetID: 1, channel: 0,
            port: port, payload: [], rxTime: Instant(nanosecondsSinceEpoch: 0)
        )
    }

    @Test
    func `setObservations derives signal, hops, peers and activity`() throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let viewModel = NodeAnalyticsViewModel(store: store, nodeNum: nodeNum)
        viewModel.setObservations([
            observation(snr: -4, rssi: -90, hopStart: 3, hopLimit: 1, gateway: "gw-a", rxNanos: 0),
            observation(snr: -6, rssi: -88, hopStart: 3, hopLimit: 1, gateway: "gw-a", rxNanos: 0),
            observation(
                snr: -12,
                rssi: -100,
                hopStart: 2,
                hopLimit: 2,
                gateway: "gw-b",
                rxNanos: 5 * 3600 * 1_000_000_000
            )
        ])

        #expect(viewModel.hasData)
        #expect(viewModel.observationCount == 3)
        #expect(viewModel.snr.sampleCount == 3)
        #expect(viewModel.rssi.sampleCount == 3)
        // Two observations at 2 hops, one at 0 hops.
        #expect(viewModel.hops.first(where: { $0.hops == 2 })?.count == 2)
        #expect(viewModel.hops.first(where: { $0.hops == 0 })?.count == 1)
        // gw-a heard it twice → ranked first.
        #expect(viewModel.peers.first?.gatewayID == "gw-a")
        #expect(viewModel.hourly.count == 24)
        #expect(viewModel.hourly[0].count == 2)
        #expect(viewModel.hourly[5].count == 1)
    }

    @Test
    func `setPackets derives the packet-type breakdown`() throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let viewModel = NodeAnalyticsViewModel(store: store, nodeNum: nodeNum)
        viewModel.setPackets([packet(port: .telemetry), packet(port: .telemetry), packet(port: .position)])
        #expect(viewModel.packetCount == 3)
        #expect(viewModel.packetTypes.first?.port == .telemetry)
        #expect(viewModel.packetTypes.first?.count == 2)
    }

    @Test
    func `ingest appends to the live feeds and recomputes`() throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let viewModel = NodeAnalyticsViewModel(store: store, nodeNum: nodeNum)
        viewModel.ingest(observation: observation(snr: -5, gateway: "gw-a"))
        viewModel.ingest(observation: observation(snr: -7, gateway: "gw-a"))
        viewModel.ingest(packet: packet(port: .nodeInfo))
        #expect(viewModel.observationCount == 2)
        #expect(viewModel.snr.sampleCount == 2)
        #expect(viewModel.packetTypes.first?.port == .nodeInfo)
    }

    @Test
    func `loadHeader reads the node display name from the store`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        try await store.upsertNode(
            NodeRecord(node_num: nodeNum, short_name: "BASE", first_seen_at: 0, last_heard_at: 0)
        )
        let viewModel = NodeAnalyticsViewModel(store: store, nodeNum: nodeNum)
        try await viewModel.loadHeader()
        #expect(viewModel.nodeName == "BASE")
    }

    @Test
    func `a fresh view model has no data`() throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let viewModel = NodeAnalyticsViewModel(store: store, nodeNum: nodeNum)
        #expect(!viewModel.hasData)
        #expect(viewModel.snr == .empty)
        #expect(viewModel.packetTypes.isEmpty)
    }
}
