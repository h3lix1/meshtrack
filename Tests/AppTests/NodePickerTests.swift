// NodePickerTests — covers the node-picker view model: the pure ranking (data
// nodes first, then most-recent activity), the name/hex search filter, and the
// store-backed default selection that fixes the "Telemetry shows no data" bug —
// the default must land on a node that actually has data, not merely the
// most-recently-heard one.

@testable import App
import Domain
import Persistence
import Testing

@Suite("NodePicker")
@MainActor
struct NodePickerTests {
    private func node(_ num: Int64, name: String, lastHeard: Int64) -> NodeRecord {
        NodeRecord(node_num: num, short_name: name, first_seen_at: 0, last_heard_at: lastHeard)
    }

    private func fix(_ num: Int64, t: Int64) -> PositionFixRecord {
        PositionFixRecord(node_num: num, t: t, lat: 37.8, lon: -122.2)
    }

    @Test
    func `ranking puts nodes with position data ahead of bare liveness`() {
        // `heard` was heard most recently but has no fix; `withFix` is older yet
        // has a position. The data node must rank first.
        let nodes = [
            node(0x01, name: "heard", lastHeard: 9000),
            node(0x02, name: "withFix", lastHeard: 1000)
        ]
        let fixes: [Int64: PositionFixRecord] = [0x02: fix(0x02, t: 1000)]
        let ranked = NodePickerViewModel.rank(nodes: nodes, latestFixes: fixes)
        #expect(ranked.first?.nodeNum == 0x02)
        #expect(ranked.first?.hasPositionData == true)
        #expect(ranked.last?.nodeNum == 0x01)
    }

    @Test
    func `among data nodes the most-recent activity wins`() {
        let nodes = [
            node(0x01, name: "old", lastHeard: 1000),
            node(0x02, name: "new", lastHeard: 2000)
        ]
        let fixes: [Int64: PositionFixRecord] = [0x01: fix(0x01, t: 1000), 0x02: fix(0x02, t: 2000)]
        let ranked = NodePickerViewModel.rank(nodes: nodes, latestFixes: fixes)
        #expect(ranked.map(\.nodeNum) == [0x02, 0x01])
    }

    @Test
    func `a newer position fix lifts a node above its last-heard time`() {
        // last_heard is stale but a fresh fix arrived later — activity is the max
        // of the two, so this node still ranks ahead.
        let nodes = [
            node(0x01, name: "fresh-fix", lastHeard: 1000),
            node(0x02, name: "stale", lastHeard: 5000)
        ]
        let fixes: [Int64: PositionFixRecord] = [0x01: fix(0x01, t: 9000), 0x02: fix(0x02, t: 4000)]
        let ranked = NodePickerViewModel.rank(nodes: nodes, latestFixes: fixes)
        #expect(ranked.first?.nodeNum == 0x01)
    }

    @Test
    func `entries carry display name and hex id`() {
        let ranked = NodePickerViewModel.rank(
            nodes: [node(0xA1B2_C3D4, name: "Oakland", lastHeard: 1)],
            latestFixes: [:]
        )
        #expect(ranked.first?.name == "Oakland")
        #expect(ranked.first?.hexID == "!a1b2c3d4")
        #expect(ranked.first?.hasPositionData == false)
    }

    @Test
    func `load defaults the selection to the strongest candidate`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        try await store.upsertNode(node(0x01, name: "heard", lastHeard: 9000))
        try await store.upsertNode(node(0x02, name: "withFix", lastHeard: 1000))
        _ = try await store.appendPositionFix(fix(0x02, t: 1000))

        let viewModel = NodePickerViewModel(store: store)
        try await viewModel.load()

        #expect(viewModel.loaded)
        #expect(viewModel.selection == 0x02, "default should be the node with a position fix")
        #expect(viewModel.entries.count == 2)
    }

    @Test
    func `load on an empty store reports empty, not loading`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let viewModel = NodePickerViewModel(store: store)
        try await viewModel.load()
        #expect(viewModel.loaded)
        #expect(viewModel.isEmpty)
        #expect(viewModel.selection == nil)
    }

    @Test
    func `search filters by name and hex without dropping the selection`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        try await store.upsertNode(node(0xA1B2_C3D4, name: "Oakland", lastHeard: 2))
        try await store.upsertNode(node(0x1111_2222, name: "Berkeley", lastHeard: 1))
        let viewModel = NodePickerViewModel(store: store)
        try await viewModel.load()
        let selected = viewModel.selection

        viewModel.searchText = "berk"
        #expect(viewModel.filteredEntries.map(\.name) == ["Berkeley"])

        viewModel.searchText = "!a1b2"
        #expect(viewModel.filteredEntries.map(\.name) == ["Oakland"])

        // Filtering never mutates the active selection.
        #expect(viewModel.selection == selected)
    }

    @Test
    func `select ignores an unknown node number`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        try await store.upsertNode(node(0x01, name: "a", lastHeard: 1))
        let viewModel = NodePickerViewModel(store: store)
        try await viewModel.load()
        viewModel.select(0xDEAD)
        #expect(viewModel.selection == 0x01)
        viewModel.select(0x01)
        #expect(viewModel.selection == 0x01)
    }
}
