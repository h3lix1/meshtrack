@testable import App
import Provisioning
import Testing

private enum UnreadableChannelError: Error {
    case unreadable
}

@Suite("FleetRolloutViewModel — live safe rolling rollout (SPEC §2.7, G7)")
@MainActor
struct FleetRolloutViewModelTests {
    // MARK: Fake admin channels (the injected effect)

    /// Accepts applies and reflects them on read-back → the node verifies.
    private actor GoodChannel: AdminChannel {
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

    /// Drops applies → read-back still differs → verification fails (node didn't take it).
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

    /// Throws on read-back → the dry-run preview can't plan the node.
    private struct UnreadableChannel: AdminChannel {
        func currentConfig() throws -> [String: String] {
            throw UnreadableChannelError.unreadable
        }

        func apply(_: [ConfigChange]) {}
    }

    private let template = NodeTemplate(name: "fleet-std", region: "US", role: "CLIENT")

    private func member(_ num: Int64) -> FleetMember {
        FleetMember(nodeNum: num, context: NamingContext(id: "!\(String(num, radix: 16))"))
    }

    private func channels(
        _ map: [Int64: any AdminChannel]
    ) -> @Sendable (Int64) -> any AdminChannel {
        { map[$0] ?? GoodChannel([:]) }
    }

    // MARK: Preview (dry-run)

    @Test
    func `preview surfaces the per-node diff without mutating, no-op nodes flagged`() async throws {
        // Node 1 needs changes; node 2 already matches the template (idempotent).
        let matching = try template.desiredConfig(for: member(2).context)
        let vm = FleetRolloutViewModel(
            channelFor: channels([1: GoodChannel([:]), 2: GoodChannel(matching)]),
            template: template,
            members: [member(1), member(2)]
        )

        await vm.preview()

        let node1 = try #require(vm.rows.first { $0.id == 1 })
        let node2 = try #require(vm.rows.first { $0.id == 2 })
        #expect(!node1.changes.isEmpty) // region/role to set → real diff
        #expect(node1.status == .pending) // previewed, not yet rolled out
        #expect(node2.changes.isEmpty)
        #expect(node2.status == .noChange) // already matches
        #expect(vm.phase == .idle)
    }

    @Test
    func `preview marks a node that fails to read back as failed`() async {
        let vm = FleetRolloutViewModel(
            channelFor: { _ in UnreadableChannel() },
            template: template,
            members: [member(1)]
        )

        await vm.preview()

        if case .failed = vm.rows.first?.status {} else { Issue.record("expected failed preview") }
    }

    // MARK: Rollout — success path

    @Test
    func `success path verifies every node in order and reports full progress`() async {
        let vm = FleetRolloutViewModel(
            channelFor: channels([
                1: GoodChannel(["region": "EU_868"]),
                2: GoodChannel([:]),
                3: GoodChannel([:])
            ]),
            template: template,
            members: [member(1), member(2), member(3)]
        )

        vm.startRollout()
        await waitUntilSettled(vm)

        #expect(vm.rows.map(\.id) == [1, 2, 3])
        #expect(vm.rows.allSatisfy { $0.status == .verified })
        #expect(vm.verifiedCount == 3)
        #expect(!vm.hasFailure)
        #expect(vm.progress == 1.0)
        #expect(vm.phase == .finished)
    }

    // MARK: Rollout — halt-on-failure path

    @Test
    func `a failing node halts the rollout so the fleet can't be destabilised`() async {
        // Node 2 drops the apply → verification fails → rollout must stop before node 3.
        let vm = FleetRolloutViewModel(
            channelFor: channels([
                1: GoodChannel([:]),
                2: BrokenChannel(["region": "EU_868"]),
                3: GoodChannel([:])
            ]),
            template: template,
            members: [member(1), member(2), member(3)]
        )

        vm.startRollout()
        await waitUntilSettled(vm)

        #expect(vm.rows[0].status == .verified)
        if case .failed = vm.rows[1].status {} else { Issue.record("node 2 should have failed") }
        #expect(vm.rows[2].status == .pending) // node 3 never attempted
        #expect(vm.hasFailure)
        #expect(vm.verifiedCount == 1)
        #expect(vm.phase == .finished)
    }

    @Test
    func `with haltOnFailure off the rollout continues past a failure`() async {
        let vm = FleetRolloutViewModel(
            channelFor: channels([
                1: GoodChannel([:]),
                2: BrokenChannel(["region": "EU_868"]),
                3: GoodChannel([:])
            ]),
            template: template,
            members: [member(1), member(2), member(3)],
            haltOnFailure: false
        )

        vm.startRollout()
        await waitUntilSettled(vm)

        #expect(vm.rows[0].status == .verified)
        if case .failed = vm.rows[1].status {} else { Issue.record("node 2 should have failed") }
        #expect(vm.rows[2].status == .verified) // node 3 still attempted + verified
        #expect(vm.verifiedCount == 2)
    }

    // MARK: Rollout — idempotent no-op path

    @Test
    func `a node already matching the template is an idempotent no-op`() async throws {
        let matching = try template.desiredConfig(for: member(1).context)
        let vm = FleetRolloutViewModel(
            channelFor: { _ in GoodChannel(matching) },
            template: template,
            members: [member(1)]
        )

        vm.startRollout()
        await waitUntilSettled(vm)

        #expect(vm.rows.first?.status == .noChange)
        #expect(vm.verifiedCount == 1) // no-op counts as success
        #expect(!vm.hasFailure)
        #expect(vm.phase == .finished)
    }

    // MARK: Helpers

    /// Spin the main actor until the rollout reaches a terminal phase.
    private func waitUntilSettled(_ vm: FleetRolloutViewModel) async {
        for _ in 0 ..< 1000 where vm.phase == .rolling {
            await Task.yield()
        }
    }
}
