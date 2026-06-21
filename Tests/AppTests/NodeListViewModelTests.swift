@testable import App
import Domain
import Persistence
import Testing

@Suite("NodeListViewModel")
struct NodeListViewModelTests {
    @Test
    func `display formats the name and hex id, falling back to hex when unnamed`() {
        let named = NodeListViewModel.display(
            NodeRecord(node_num: 0xA1B2_C3D4, short_name: "BASE", first_seen_at: 0, last_heard_at: 10)
        )
        #expect(named.name == "BASE")
        #expect(named.hexID == "!a1b2c3d4")

        let unnamed = NodeListViewModel.display(NodeRecord(
            node_num: 0x09,
            first_seen_at: 0,
            last_heard_at: 0
        ))
        #expect(unnamed.name == "!00000009")
    }

    @Test
    @MainActor
    func `load lists nodes most-recently-heard first`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        try await store.markHeard(nodeNum: 1, at: Instant(nanosecondsSinceEpoch: 100))
        try await store.markHeard(nodeNum: 2, at: Instant(nanosecondsSinceEpoch: 200))

        let viewModel = NodeListViewModel(store: store)
        try await viewModel.load()
        #expect(viewModel.nodes.map(\.nodeNum) == [2, 1])
    }
}
