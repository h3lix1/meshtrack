@testable import Provisioning
import Testing

@Suite("AdminApplier flow (SPEC §2.7)")
struct AdminApplierTests {
    /// In-memory admin channel that actually applies changes.
    private actor FakeChannel: AdminChannel {
        private var config: [String: String]
        init(_ config: [String: String]) {
            self.config = config
        }

        func currentConfig() -> [String: String] {
            config
        }

        func apply(_ changes: [ConfigChange]) {
            for change in changes {
                config[change.field] = change.to
            }
        }
    }

    /// A channel that silently drops applies — to exercise read-back verification.
    private actor BrokenChannel: AdminChannel {
        private let config: [String: String]
        init(_ config: [String: String]) {
            self.config = config
        }

        func currentConfig() -> [String: String] {
            config
        }

        func apply(_: [ConfigChange]) {}
    }

    private let template = NodeTemplate(
        name: "t", region: "US", role: "CLIENT", shortNameDSL: "{id[-4:]}"
    )
    private let context = NamingContext(id: "!aabbA123", shortName: "baymesh")

    @Test
    func `plan diffs the template against the live node`() async throws {
        let channel = FakeChannel(["region": "EU_868"])
        let plan = try await AdminApplier(channel: channel).plan(template: template, context: context)
        #expect(Set(plan.changes.map(\.field)) == ["region", "role", "short_name"])
    }

    @Test
    func `apply mutates the node and read-back verifies idempotency`() async throws {
        let channel = FakeChannel([:])
        let applier = AdminApplier(channel: channel)
        let plan = try await applier.plan(template: template, context: context)
        #expect(!plan.isNoOp)
        try await applier.apply(plan, template: template, context: context)
        // A fresh plan against the now-updated node is a no-op.
        #expect(try await applier.plan(template: template, context: context).isNoOp)
    }

    @Test
    func `a matching node yields a no-op plan that applies nothing`() async throws {
        let desired = try template.desiredConfig(for: context)
        let applier = AdminApplier(channel: FakeChannel(desired))
        let plan = try await applier.plan(template: template, context: context)
        #expect(plan.isNoOp)
        try await applier.apply(plan, template: template, context: context) // no throw
    }

    @Test
    func `a node that drops the apply fails read-back verification`() async throws {
        let applier = AdminApplier(channel: BrokenChannel(["region": "EU_868"]))
        let plan = try await applier.plan(template: template, context: context)
        await #expect(throws: ApplyError.self) {
            try await applier.apply(plan, template: template, context: context)
        }
    }
}
