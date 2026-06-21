import Domain
@testable import Persistence
import Testing

@Suite("MeshStore: fleet config storage (templates + node_config)")
struct FleetStoreTests {
    private func makeStore() throws -> MeshStore {
        try MeshStore(DatabaseConnection.inMemory())
    }

    @Test
    func `templates insert with id, list by name, update in place, delete`() async throws {
        let store = try makeStore()
        #expect(try await store.allTemplates().isEmpty)

        let id = try await store.upsertTemplate(TemplateRecord(
            name: "Bravo",
            dsl: "{shortName}",
            region: "US"
        ))
        #expect(id > 0)
        _ = try await store.upsertTemplate(TemplateRecord(name: "Alpha", dsl: "x", region: "EU"))

        #expect(try await store.allTemplates().map(\.name) == ["Alpha", "Bravo"]) // ordered

        // Update in place (same id) — count stays 2, name changes.
        _ = try await store.upsertTemplate(TemplateRecord(id: id, name: "Bravo2", dsl: "y", region: "US"))
        let names = try await store.allTemplates().map(\.name)
        #expect(names == ["Alpha", "Bravo2"])

        try await store.deleteTemplate(id: id)
        #expect(try await store.allTemplates().map(\.name) == ["Alpha"])
    }

    @Test
    func `node_config round-trips and overwrites`() async throws {
        let store = try makeStore()
        try await store.upsertNode(NodeRecord(node_num: 7, first_seen_at: 0, last_heard_at: 0))
        #expect(try await store.fetchNodeConfig(nodeNum: 7) == nil)

        try await store.saveNodeConfig(NodeConfigRecord(node_num: 7, region: "US", position_precision: 16))
        let loaded = try await store.fetchNodeConfig(nodeNum: 7)
        #expect(loaded?.region == "US")
        #expect(loaded?.position_precision == 16)

        try await store.saveNodeConfig(NodeConfigRecord(node_num: 7, region: "EU", position_precision: 12))
        #expect(try await store.fetchNodeConfig(nodeNum: 7)?.region == "EU")
    }
}
