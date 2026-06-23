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
    func `a saved template carries broad config fields through persistence`() async throws {
        // Phase 10: the editor's broad form (`configForm`) feeds group defaults into
        // the template; they must survive save → reload via `config_json`.
        let store = try makeStore()
        let viewModel = FleetConfigViewModel(store: store)
        await viewModel.load()

        viewModel.newTemplate()
        viewModel.draft.name = "Broad Fleet"
        viewModel.draft.region = "US"
        // Operator edits broad fields in the shared form.
        viewModel.configForm.set("MEDIUM_FAST", for: "modem_preset")
        viewModel.configForm.set("true", for: "mqtt_enabled")
        viewModel.configForm.set("20", for: "tx_power")
        await viewModel.saveTemplate()

        // The in-memory template already reflects the broad fields.
        let template = viewModel.currentTemplate()
        #expect(template.fields["modem_preset"] == "MEDIUM_FAST")
        #expect(template.fields["mqtt_enabled"] == "true")

        // Reselecting a fresh load reseeds the draft + form from persistence.
        let id = try #require(viewModel.selectedTemplateID)
        viewModel.newTemplate()
        #expect(viewModel.configForm.values["modem_preset"] == nil) // cleared by new draft
        viewModel.select(id)
        #expect(viewModel.draft.fields["modem_preset"] == "MEDIUM_FAST")
        #expect(viewModel.draft.fields["mqtt_enabled"] == "true")
        #expect(viewModel.draft.fields["tx_power"] == "20")
        #expect(viewModel.configForm.values["modem_preset"] == "MEDIUM_FAST")
    }

    @Test
    func `an edit in the broad form overrides the seeded default without clobbering scalars`() async throws {
        let store = try makeStore()
        let viewModel = FleetConfigViewModel(store: store)
        await viewModel.load()
        viewModel.newTemplate()
        viewModel.draft.name = "Edit Fleet"
        viewModel.draft.role = "ROUTER" // set via the draft scalar (not the form)
        viewModel.configForm.set("LONG_SLOW", for: "modem_preset") // set via the form
        await viewModel.saveTemplate()

        let id = try #require(viewModel.selectedTemplateID)
        viewModel.select(id)
        // Both the scalar-set role and the form-set modem preset persisted.
        #expect(viewModel.draft.role == "ROUTER")
        #expect(viewModel.draft.fields["modem_preset"] == "LONG_SLOW")
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

    @Test
    func `store-backed channel rejects an invalid region before persisting`() async throws {
        // Validation lives in the shared AdminApplier orchestration, so the GUI-wired
        // store-backed adapter inherits it: a typo'd region is rejected up front rather
        // than written to the record and then "verified" as success.
        let store = try makeStore()
        try await seed(store, node: 1, role: "CLIENT", short: "old")

        let channel = StoreBackedAdminChannel(store: store, nodeNum: 1)
        let applier = AdminApplier(channel: channel)
        let template = NodeTemplate(name: "t", region: "US", role: "ROUTER", shortNameDSL: "new")
        let context = NamingContext(id: "!00000001", shortName: "old", role: "CLIENT")

        // A plan carrying a bogus region (e.g. a template typo) must not reach the store.
        let plan = ApplyPlan(changes: [ConfigChange(field: "region", from: nil, to: "UX")])
        await #expect(throws: AdminMappingError.unknownRegion("UX")) {
            try await applier.apply(plan, template: template, context: context)
        }

        // Nothing was persisted — the node config snapshot was never written.
        #expect(try await store.fetchNodeConfig(nodeNum: 1) == nil)
    }

    @Test
    func `store-backed apply coalesces duplicate config fields (last wins, no trap)`() async throws {
        // Two changes share a field: apply must not trap on Dictionary(uniqueKeysWithValues:);
        // it coalesces to the later value rather than crashing.
        let store = try makeStore()
        try await seed(store, node: 1, role: "CLIENT")

        let channel = StoreBackedAdminChannel(store: store, nodeNum: 1)
        try await channel.apply([
            ConfigChange(field: "region", from: nil, to: "EU_868"),
            ConfigChange(field: "region", from: nil, to: "US")
        ])

        #expect(try await store.fetchNodeConfig(nodeNum: 1)?.region == "US")
    }

    @Test
    func `duplicate nodeNum candidates de-dup to one sane rollout member (no trap)`() {
        /// A node present both as a discovered node and a stored row appears twice in
        /// candidates. De-dup keeps the first per nodeNum so keying the rollout's names
        /// by nodeNum never traps and only one row is built per node.
        func candidate(_ num: Int64, name: String) -> FleetConfigViewModel.MemberCandidate {
            FleetConfigViewModel.MemberCandidate(
                nodeNum: num, name: name, hexid: FleetConfigViewModel.hexID(num),
                shortName: name, longName: nil, role: "CLIENT", isMine: true, isManaged: true
            )
        }

        let deduped = FleetConfigViewModel.dedupByNodeNum([
            candidate(1, name: "first"),
            candidate(1, name: "second"), // same nodeNum — the trapping duplicate
            candidate(2, name: "other")
        ])

        #expect(deduped.map(\.nodeNum) == [1, 2])
        #expect(deduped.first { $0.nodeNum == 1 }?.name == "first") // first wins
        // Keying by nodeNum is now safe — this would have trapped on the duplicate.
        let names = Dictionary(uniqueKeysWithValues: deduped.map { ($0.nodeNum, $0.name) })
        #expect(names == [1: "first", 2: "other"])
    }
}
