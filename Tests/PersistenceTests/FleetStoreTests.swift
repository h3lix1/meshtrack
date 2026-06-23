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
    func `a template's broad config_json round-trips through the store intact`() async throws {
        // Phase 10: the full protocol surface a template carries is JSON-encoded into
        // the existing `config_json` column (no migration). Prove the column persists
        // and reloads a non-trivial payload byte-for-byte.
        let store = try makeStore()
        let json = #"{"fields":{"modem_preset":"MEDIUM_FAST","mqtt_enabled":"true","tx_power":"20"}}"#
        let id = try await store.upsertTemplate(TemplateRecord(
            name: "Broad",
            dsl: "{shortName}",
            region: "US",
            role: "ROUTER",
            config_json: json
        ))

        let loaded = try #require(try await store.allTemplates().first { $0.id == id })
        #expect(loaded.config_json == json)
        #expect(loaded.role == "ROUTER")

        // Overwrite in place with a different payload — the new JSON replaces the old.
        let json2 = #"{"fields":{"hop_limit":"5"}}"#
        _ = try await store.upsertTemplate(TemplateRecord(
            id: id, name: "Broad", dsl: "{shortName}", region: "US", role: "ROUTER", config_json: json2
        ))
        #expect(try await store.allTemplates().first { $0.id == id }?.config_json == json2)
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
