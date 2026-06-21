@testable import App
import Domain
import Persistence
import Testing

@Suite("NodeDirectoryViewModel")
@MainActor
struct NodeDirectoryViewModelTests {
    /// Seed a store with a representative fleet: roles + ownership flags.
    private func seededStore() async throws -> MeshStore {
        let store = try MeshStore(DatabaseConnection.inMemory())
        for record in [
            node(0xA1B2_C3D4, "BASE", role: "ROUTER", mine: true, managed: true, heard: 9000),
            node(0x0000_0F01, "RPTR", role: "REPEATER", mine: true, managed: true, heard: 8000),
            node(0x0000_0C02, "TRK1", role: "TRACKER", mine: true, managed: false, heard: 7000),
            node(0x0000_0C03, "PHON", role: "CLIENT", mine: true, managed: false, heard: 6000),
            node(0x0000_0E04, "STR1", role: "CLIENT", mine: false, managed: false, heard: 5000),
            node(0x0000_0E05, "STR2", role: "ROUTER", mine: false, managed: false, heard: 4000)
        ] {
            try await store.upsertNode(record)
        }
        return store
    }

    private func node(
        _ num: Int64,
        _ shortName: String,
        role: String,
        mine: Bool,
        managed: Bool,
        heard: Int64
    ) -> NodeRecord {
        NodeRecord(
            node_num: num,
            short_name: shortName,
            node_class: role == "ROUTER" ? .gateway : .mobile,
            role: role,
            first_seen_at: 0,
            last_heard_at: heard,
            is_mine: mine,
            is_managed: managed
        )
    }

    // MARK: Loading + ordering

    @Test
    func `load lists every node most-recently-heard first`() async throws {
        let viewModel = try await NodeDirectoryViewModel(store: seededStore())
        try await viewModel.load()
        #expect(viewModel.totalCount == 6)
        #expect(viewModel.visible.first?.name == "BASE") // heard 9000 (newest)
        #expect(viewModel.visible.map(\.nodeNum) == [
            0xA1B2_C3D4, 0x0000_0F01, 0x0000_0C02, 0x0000_0C03, 0x0000_0E04, 0x0000_0E05
        ])
    }

    // MARK: Role inference + tabs

    @Test
    func `role inference maps firmware roles and falls back to class`() {
        #expect(NodeRole.infer(role: "ROUTER_CLIENT", nodeClass: .unknown) == .router)
        #expect(NodeRole.infer(role: "REPEATER", nodeClass: .unknown) == .repeater)
        #expect(NodeRole.infer(role: "TRACKER", nodeClass: .mobile) == .tracker)
        #expect(NodeRole.infer(role: "CLIENT_MUTE", nodeClass: .unknown) == .client)
        #expect(NodeRole.infer(role: nil, nodeClass: .gateway) == .gateway)
        #expect(NodeRole.infer(role: nil, nodeClass: .mobile) == .other)
    }

    @Test
    func `presentRoles lists only roles that have nodes, in canonical order`() async throws {
        let viewModel = try await NodeDirectoryViewModel(store: seededStore())
        try await viewModel.load()
        // Fleet has client, router, repeater, tracker — not sensor/gateway/other.
        #expect(viewModel.presentRoles == [.client, .router, .repeater, .tracker])
    }

    @Test
    func `role filter narrows to a single role`() async throws {
        let viewModel = try await NodeDirectoryViewModel(store: seededStore())
        try await viewModel.load()
        viewModel.roleFilter = .role(.router)
        #expect(Set(viewModel.visible.map(\.name)) == ["BASE", "STR2"])
        viewModel.roleFilter = .all
        #expect(viewModel.visible.count == 6)
    }

    // MARK: Search

    @Test
    func `search matches name case-insensitively`() async throws {
        let viewModel = try await NodeDirectoryViewModel(store: seededStore())
        try await viewModel.load()
        viewModel.searchText = "base"
        #expect(viewModel.visible.map(\.name) == ["BASE"])
    }

    @Test
    func `search matches hex id`() async throws {
        let viewModel = try await NodeDirectoryViewModel(store: seededStore())
        try await viewModel.load()
        viewModel.searchText = "a1b2"
        #expect(viewModel.visible.map(\.name) == ["BASE"])
    }

    @Test
    func `blank or whitespace search shows everything`() async throws {
        let viewModel = try await NodeDirectoryViewModel(store: seededStore())
        try await viewModel.load()
        viewModel.searchText = "   "
        #expect(viewModel.visible.count == 6)
    }

    // MARK: My Nodes

    @Test
    func `my nodes toggle narrows to is_mine`() async throws {
        let viewModel = try await NodeDirectoryViewModel(store: seededStore())
        try await viewModel.load()
        #expect(viewModel.myNodesCount == 4)
        viewModel.myNodesOnly = true
        #expect(viewModel.visible.count == 4)
        let allMine = viewModel.visible.allSatisfy(\.isMine)
        #expect(allMine)
    }

    @Test
    func `filters compose — my nodes + role + search`() async throws {
        let viewModel = try await NodeDirectoryViewModel(store: seededStore())
        try await viewModel.load()
        viewModel.myNodesOnly = true
        viewModel.roleFilter = .role(.router)
        // Of the routers (BASE, STR2) only BASE is mine.
        #expect(viewModel.visible.map(\.name) == ["BASE"])
        viewModel.searchText = "nope"
        #expect(viewModel.visible.isEmpty)
    }

    // MARK: Segmentation

    @Test
    func `segmentation partitions the visible set with counts`() async throws {
        let viewModel = try await NodeDirectoryViewModel(store: seededStore())
        try await viewModel.load()
        #expect(viewModel.count(in: .managed) == 2) // BASE, RPTR
        #expect(viewModel.count(in: .unmanaged) == 4)
        let allManaged = viewModel.entries(in: .managed).allSatisfy(\.isManaged)
        let noneManaged = viewModel.entries(in: .unmanaged).allSatisfy { !$0.isManaged }
        #expect(allManaged)
        #expect(noneManaged)
    }

    @Test
    func `segment counts honour active filters`() async throws {
        let viewModel = try await NodeDirectoryViewModel(store: seededStore())
        try await viewModel.load()
        viewModel.myNodesOnly = true
        // Of my 4 nodes: BASE + RPTR managed; TRK1 + PHON unmanaged.
        #expect(viewModel.count(in: .managed) == 2)
        #expect(viewModel.count(in: .unmanaged) == 2)
    }

    // MARK: Selection + bulk-classify

    @Test
    func `toggle selection adds then removes`() async throws {
        let viewModel = try await NodeDirectoryViewModel(store: seededStore())
        try await viewModel.load()
        viewModel.toggleSelection(0x0000_0E04)
        #expect(viewModel.isSelected(0x0000_0E04))
        viewModel.toggleSelection(0x0000_0E04)
        #expect(!viewModel.isSelected(0x0000_0E04))
    }

    @Test
    func `select all visible respects the active filter`() async throws {
        let viewModel = try await NodeDirectoryViewModel(store: seededStore())
        try await viewModel.load()
        viewModel.roleFilter = .role(.router)
        viewModel.selectAllVisible()
        #expect(viewModel.selection == [0xA1B2_C3D4, 0x0000_0E05])
    }

    @Test
    func `classify selection marks managed and clears selection`() async throws {
        let store = try await seededStore()
        let viewModel = NodeDirectoryViewModel(store: store)
        try await viewModel.load()
        // Two strangers' nodes, currently unmanaged.
        viewModel.toggleSelection(0x0000_0E04)
        viewModel.toggleSelection(0x0000_0E05)
        let updated = try await viewModel.classifySelection(isManaged: true)
        #expect(updated == 2)
        #expect(viewModel.selection.isEmpty)
        // Cache reflects the change…
        #expect(viewModel.count(in: .managed) == 4)
        // …and so does the store.
        #expect(try await store.isManaged(nodeNum: 0x0000_0E04))
        #expect(try await store.isManaged(nodeNum: 0x0000_0E05))
    }

    @Test
    func `classify mine leaves managed untouched`() async throws {
        let store = try await seededStore()
        let viewModel = NodeDirectoryViewModel(store: store)
        try await viewModel.load()
        viewModel.toggleSelection(0x0000_0E04) // stranger, unmanaged, not mine
        let updated = try await viewModel.classifySelection(isMine: true)
        #expect(updated == 1)
        let entry = try #require(viewModel.allEntries.first { $0.nodeNum == 0x0000_0E04 })
        #expect(entry.isMine)
        #expect(!entry.isManaged) // managed left alone
    }

    @Test
    func `classify with empty selection is a no-op`() async throws {
        let viewModel = try await NodeDirectoryViewModel(store: seededStore())
        try await viewModel.load()
        let updated = try await viewModel.classifySelection(isManaged: true)
        #expect(updated == 0)
    }

    // MARK: Drill-through

    @Test
    func `selected node num is the analytics drill-through seam`() async throws {
        let viewModel = try await NodeDirectoryViewModel(store: seededStore())
        try await viewModel.load()
        #expect(viewModel.selectedNodeNum == nil)
        viewModel.selectedNodeNum = 0xA1B2_C3D4
        #expect(viewModel.selectedNodeNum == 0xA1B2_C3D4)
    }

    // MARK: Formatting

    @Test
    func `entry formats name, hex, role and ownership`() {
        let entry = NodeDirectoryViewModel.entry(
            NodeRecord(
                node_num: 0xA1B2_C3D4, short_name: "BASE", node_class: .gateway, role: "ROUTER",
                first_seen_at: 0, last_heard_at: 10, is_mine: true, is_managed: true
            )
        )
        #expect(entry.name == "BASE")
        #expect(entry.hexID == "!a1b2c3d4")
        #expect(entry.role == .router)
        #expect(entry.isMine)
        #expect(entry.isManaged)
    }

    @Test
    func `entry falls back to hex when unnamed`() {
        let entry = NodeDirectoryViewModel.entry(NodeRecord(
            node_num: 0x09,
            first_seen_at: 0,
            last_heard_at: 0
        ))
        #expect(entry.name == "!00000009")
        #expect(entry.role == .other)
    }
}
