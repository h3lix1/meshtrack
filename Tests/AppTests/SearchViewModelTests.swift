@testable import App
import Domain
import Persistence
import Testing

@Suite("Search view model")
struct SearchViewModelTests {
    @Test
    @MainActor
    func `setting the query recomputes ranked results`() {
        let viewModel = SearchViewModel(corpus: SearchPreviewData.corpus())
        #expect(viewModel.results.isEmpty)
        viewModel.query = "base"
        #expect(viewModel.results.first?.item.title == "BASE")
    }

    @Test
    @MainActor
    func `selecting a result records the deep-link target and dismisses`() {
        let viewModel = SearchViewModel(corpus: SearchPreviewData.corpus())
        viewModel.isPresented = true
        viewModel.query = "base"
        guard let first = viewModel.results.first else {
            Issue.record("expected a result")
            return
        }
        viewModel.select(first)
        #expect(viewModel.selectedTarget == .node(nodeNum: 0xA1B2_C3D4))
        #expect(viewModel.isPresented == false)
    }

    @Test
    @MainActor
    func `consuming the target clears it for the next selection`() {
        let viewModel = SearchViewModel(corpus: SearchPreviewData.corpus())
        viewModel.query = "ops"
        if let first = viewModel.results.first { viewModel.select(first) }
        #expect(viewModel.selectedTarget == .channel(channel: 1))
        viewModel.consumeTarget()
        #expect(viewModel.selectedTarget == nil)
    }

    @Test
    @MainActor
    func `open resets the query and presents`() {
        let viewModel = SearchViewModel(corpus: SearchPreviewData.corpus())
        viewModel.query = "stale"
        viewModel.open()
        #expect(viewModel.query == "")
        #expect(viewModel.results.isEmpty)
        #expect(viewModel.isPresented)
    }

    @Test
    @MainActor
    func `reloadCorpus builds nodes, channels and packets from the store`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        try await store.upsertNode(NodeRecord(
            node_num: 0xA1B2_C3D4, short_name: "BASE", first_seen_at: 0, last_heard_at: 10
        ))
        _ = try await store.recordMessage(MessageRecord(
            packet_id: 7777, from_num: 0xA1B2_C3D4, to_num: 0xFFFF_FFFF,
            channel: 0, channel_name: "LongFast", body: "hi", rx_time: 5, is_dm: false
        ))

        let viewModel = SearchViewModel(store: store)
        try await viewModel.reloadCorpus()

        // Node by name.
        viewModel.query = "base"
        #expect(viewModel.results.contains { $0.item.target == .node(nodeNum: 0xA1B2_C3D4) })
        // Channel by name.
        viewModel.query = "LongFast"
        #expect(viewModel.results.contains { $0.item.target == .channel(channel: 0) })
        // Packet by id.
        viewModel.query = "7777"
        #expect(viewModel.results.contains { $0.item.target == .packet(packetID: 7777) })
    }

    @Test
    @MainActor
    func `store reload dedupes channels across messages`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        for index in 0..<3 {
            _ = try await store.recordMessage(MessageRecord(
                packet_id: Int64(100 + index), from_num: 1, to_num: 2,
                channel: 0, channel_name: "Ops", body: "m\(index)", rx_time: Int64(index), is_dm: false
            ))
        }
        let viewModel = SearchViewModel(store: store)
        try await viewModel.reloadCorpus()
        viewModel.query = "Ops"
        let channelHits = viewModel.results.filter {
            if case .channel = $0.item.target { return true }
            return false
        }
        #expect(channelHits.count == 1)
    }
}
