@testable import App
import Domain
import Persistence
import Provisioning
import Testing

@Suite("FleetConfigViewModel — the fleet configuration engine")
@MainActor
struct FleetConfigViewModelTests {
    private func makeStore() throws -> MeshStore {
        try MeshStore(DatabaseConnection.inMemory())
    }

    private func seed(
        _ store: MeshStore,
        node: Int64,
        role: String? = nil,
        short: String? = nil
    ) async throws {
        try await store.upsertNode(NodeRecord(
            node_num: node, short_name: short, role: role, first_seen_at: 0, last_heard_at: 0
        ))
    }

    // MARK: Templates

    @Test
    func `save then reselect restores the draft from the persisted template`() async throws {
        let store = try makeStore()
        let viewModel = FleetConfigViewModel(store: store)
        await viewModel.load()

        viewModel.newTemplate()
        viewModel.draft.name = "Bay Fleet"
        viewModel.draft.region = "US"
        viewModel.draft.role = "ROUTER"
        viewModel.draft.shortNameDSL = "{shortName}"
        await viewModel.saveTemplate()

        #expect(viewModel.templates.contains { $0.template.name == "Bay Fleet" })
        let id = try #require(viewModel.selectedTemplateID)

        viewModel.newTemplate()
        #expect(viewModel.draft.name == "New template")
        viewModel.select(id)
        #expect(viewModel.draft.name == "Bay Fleet")
        #expect(viewModel.draft.role == "ROUTER")
        #expect(viewModel.draft.region == "US")
    }

    @Test
    func `delete removes the selected template`() async throws {
        let store = try makeStore()
        let viewModel = FleetConfigViewModel(store: store)
        await viewModel.load()
        viewModel.newTemplate()
        viewModel.draft.name = "Temp"
        await viewModel.saveTemplate()
        #expect(viewModel.templates.count == 1)
        await viewModel.deleteSelectedTemplate()
        #expect(viewModel.templates.isEmpty)
        #expect(viewModel.selectedTemplateID == nil)
    }

    // MARK: Targeting

    @Test
    func `candidates load and the My-Nodes / Managed filters narrow them`() async throws {
        let store = try makeStore()
        try await seed(store, node: 1)
        try await seed(store, node: 2)
        try await seed(store, node: 3)
        try await store.setOwnership(nodeNum: 1, isMine: true, isManaged: true)
        try await store.setOwnership(nodeNum: 2, isMine: true, isManaged: false)

        let viewModel = FleetConfigViewModel(store: store)
        await viewModel.load()
        #expect(viewModel.candidates.count == 3)

        viewModel.showManagedOnly = true
        #expect(viewModel.visibleCandidates.map(\.nodeNum) == [1])

        viewModel.showManagedOnly = false
        viewModel.showMineOnly = true
        #expect(Set(viewModel.visibleCandidates.map(\.nodeNum)) == [1, 2])
    }

    @Test
    func `preview builds a rollout with a non-empty per-node diff`() async throws {
        let store = try makeStore()
        try await seed(store, node: 1, role: "CLIENT", short: "old")

        let viewModel = FleetConfigViewModel(store: store)
        await viewModel.load()
        viewModel.draft = .init(name: "t", region: "US", role: "ROUTER", shortNameDSL: "new", longNameDSL: "")
        viewModel.selected = [1]
        await viewModel.preview()

        let rollout = try #require(viewModel.rollout)
        #expect(rollout.rows.count == 1)
        #expect(!rollout.rows[0].changes.isEmpty) // region/role/short_name differ
    }

    // MARK: End-to-end apply + verify (the real engine, via the store-backed channel)

    @Test
    func `store-backed channel applies a template and read-back verifies`() async throws {
        let store = try makeStore()
        try await seed(store, node: 1, role: "CLIENT", short: "old")

        let channel = StoreBackedAdminChannel(store: store, nodeNum: 1)
        let applier = AdminApplier(channel: channel)
        let template = NodeTemplate(name: "t", region: "US", role: "ROUTER", shortNameDSL: "new")
        let context = NamingContext(id: "!00000001", shortName: "old", role: "CLIENT")

        let plan = try await applier.plan(template: template, context: context)
        #expect(!plan.isNoOp) // region (unset→US), role (CLIENT→ROUTER), short_name (old→new)

        // apply() throws ApplyError.verificationFailed if the read-back still differs.
        try await applier.apply(plan, template: template, context: context)

        let node = try await store.fetchNode(nodeNum: 1)
        #expect(node?.role == "ROUTER")
        #expect(node?.short_name == "new")
        #expect(try await store.fetchNodeConfig(nodeNum: 1)?.region == "US")

        // Re-planning is now an idempotent no-op — proof the node took the change.
        #expect(try await applier.plan(template: template, context: context).isNoOp)
    }
}
