@testable import App
import Domain
import Persistence
import Testing

@Suite("NetworkViewModel (live network composition)")
@MainActor
struct NetworkViewModelTests {
    private func seededStore() async throws -> MeshStore {
        let store = try MeshStore(DatabaseConnection.inMemory())
        // gateway (positioned), a source node (positioned), and an unpositioned node.
        try await store.upsertNode(NodeRecord(
            node_num: 0x0000_00FF, hexid: "!000000ff", short_name: "GW",
            node_class: .gateway, first_seen_at: 0, last_heard_at: 0
        ))
        try await store.upsertNode(NodeRecord(
            node_num: 0x0000_0001, hexid: "!00000001", short_name: "SRC",
            node_class: .mobile, first_seen_at: 0, last_heard_at: 0
        ))
        try await store.upsertNode(NodeRecord(
            node_num: 0x0000_0002, hexid: "!00000002", short_name: "NOFIX",
            node_class: .mobile, first_seen_at: 0, last_heard_at: 0
        ))
        _ = try await store.appendPositionFix(PositionFixRecord(
            node_num: 0x0000_00FF,
            t: 1,
            lat: 37.5,
            lon: -122.0
        ))
        _ = try await store.appendPositionFix(PositionFixRecord(
            node_num: 0x0000_0001,
            t: 1,
            lat: 37.0,
            lon: -122.0
        ))
        return store
    }

    @Test
    func `loadNodes builds positioned nodes and ignores those without a fix`() async throws {
        let model = try await NetworkViewModel(store: seededStore())
        try await model.loadNodes()
        #expect(model.nodes.count == 2) // NOFIX is ignored
        #expect(model.nodes.contains { $0.name == "GW" && $0.isGateway })
        #expect(!model.nodes.contains { $0.name == "NOFIX" })
    }

    @Test
    func `ingesting a decoded packet produces a live trace`() async throws {
        let model = try await NetworkViewModel(store: seededStore())
        try await model.loadNodes()
        #expect(model.traces.isEmpty)
        model.ingest(DecodedPacket(
            from: 0x0000_0001, to: 0xFFFF_FFFF, packetID: 0xABCD, channel: 0,
            port: .telemetry, payload: [], rxTime: .epoch,
            hopStart: 2, hopLimit: 1, gatewayID: 0x0000_00FF
        ))
        #expect(model.traces.count == 1)
        #expect(model.traces.first?.id == 0xABCD)
    }

    @Test
    func `ingesting records the source node's channel preset`() async throws {
        let model = try await NetworkViewModel(store: seededStore())
        try await model.loadNodes()
        // LongFast's channel hash is 8.
        model.ingest(DecodedPacket(
            from: 0x0000_0001, to: 0xFFFF_FFFF, packetID: 0xABCD,
            channel: ChannelPreset.longFast.channelHash,
            port: .telemetry, payload: [], rxTime: .epoch,
            hopStart: 2, hopLimit: 1, gatewayID: 0x0000_00FF
        ))
        #expect(model.presetByNode[0x0000_0001] == .longFast)
        #expect(model.nodes.first { $0.id == 0x0000_0001 }?.preset == .longFast)
        #expect(model.availablePresets == [.longFast])
    }
}
