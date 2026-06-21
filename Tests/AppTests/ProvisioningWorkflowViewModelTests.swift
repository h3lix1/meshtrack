@testable import App
import Provisioning
import Testing

@Suite("ProvisioningWorkflowViewModel — the guided single-node flow (SPEC §2.7)")
@MainActor
struct ProvisioningWorkflowViewModelTests {
    /// An in-memory admin channel that actually applies changes (so read-back
    /// verifies). Mirrors the fleet engine's fakes.
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

    /// A channel that silently drops applies — exercises read-back verification.
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

    private func candidate(_ num: Int64 = 0x42) -> ProvisioningWorkflowViewModel.TargetCandidate {
        ProvisioningWorkflowViewModel.TargetCandidate(
            nodeNum: num, name: "BASE", hexID: "!00000042", shortName: "BASE", role: "CLIENT"
        )
    }

    private func draft() -> TemplateDraft {
        TemplateDraft(
            name: "Bay", region: "US", role: "ROUTER",
            shortNameDSL: "{shortName}", longNameDSL: "", positionPrecision: ""
        )
    }

    private func makeVM(channel: any AdminChannel) -> ProvisioningWorkflowViewModel {
        ProvisioningWorkflowViewModel(
            draft: draft(),
            channelFor: { _ in channel }
        )
    }

    // MARK: Navigation

    @Test
    func `the flow starts on the template step`() {
        let vm = makeVM(channel: FakeChannel([:]))
        #expect(vm.step == .template)
    }

    @Test
    func `cannot advance to target until a region is set`() {
        let vm = ProvisioningWorkflowViewModel(
            draft: TemplateDraft(region: ""), channelFor: { _ in FakeChannel([:]) }
        )
        #expect(!vm.canAdvance)
        vm.goToTarget()
        #expect(vm.step == .template) // gate held
    }

    @Test
    func `goToTarget then back returns to the template step`() {
        let vm = makeVM(channel: FakeChannel([:]))
        vm.goToTarget()
        #expect(vm.step == .target)
        vm.back()
        #expect(vm.step == .template)
    }

    // MARK: Preview (dry-run, no mutation)

    @Test
    func `preview diffs the template without applying and surfaces the reboot impact`() async {
        let channel = FakeChannel(["region": "EU_868", "role": "CLIENT"])
        let vm = makeVM(channel: channel)
        vm.goToTarget()
        vm.selectTarget(candidate())
        await vm.preview()

        #expect(vm.step == .preview)
        let plan = vm.plan
        #expect(plan?.isNoOp == false)
        // region + role both reboot; the warning is surfaced before any apply.
        #expect(vm.reboot.requiresReboot)
        #expect(vm.reboot.rebootingFields == ["region", "role"])
        // Nothing applied yet: a fresh read still shows the old region.
        #expect(await channel.currentConfig()["region"] == "EU_868")
    }

    @Test
    func `a node already matching the template previews as a no-op`() async {
        // Seed the node to exactly the template's desired config.
        let desired = try? draft().template.desiredConfig(
            for: NamingContext(id: "!00000042", shortName: "BASE", role: "CLIENT")
        )
        let vm = makeVM(channel: FakeChannel(desired ?? [:]))
        vm.goToTarget()
        vm.selectTarget(candidate())
        await vm.preview()
        #expect(vm.plan?.isNoOp == true)
        #expect(!vm.canAdvance) // a no-op cannot proceed to confirm
    }

    // MARK: The confirm gate — nothing applies without it

    @Test
    func `confirmAndApply is a no-op unless the confirm gate was reached`() async {
        let channel = FakeChannel(["region": "EU_868"])
        let vm = makeVM(channel: channel)
        vm.goToTarget()
        vm.selectTarget(candidate())
        await vm.preview()
        // Skip the confirm step and try to apply directly from preview.
        #expect(vm.step == .preview)
        await vm.confirmAndApply()
        // The gate held: nothing was applied and we did not advance.
        #expect(vm.step == .preview)
        #expect(vm.outcome == nil)
        #expect(await channel.currentConfig()["region"] == "EU_868")
    }

    @Test
    func `the full happy path applies and read-back verifies`() async {
        let channel = FakeChannel(["region": "EU_868", "role": "CLIENT"])
        let vm = makeVM(channel: channel)
        vm.goToTarget()
        vm.selectTarget(candidate())
        await vm.preview()
        vm.reviewForConfirmation()
        #expect(vm.step == .confirm)
        await vm.confirmAndApply()

        #expect(vm.step == .result)
        #expect(vm.outcome == .applied(rebooting: true))
        #expect(vm.outcome?.isSuccess == true)
        // The change really landed on the node.
        #expect(await channel.currentConfig()["region"] == "US")
        #expect(await channel.currentConfig()["role"] == "ROUTER")
    }

    @Test
    func `a name-only change applies without flagging a reboot`() async {
        let vm = ProvisioningWorkflowViewModel(
            draft: TemplateDraft(
                name: "n", region: "US", role: "CLIENT", shortNameDSL: "{shortName}", longNameDSL: ""
            ),
            channelFor: { _ in FakeChannel(["region": "US", "role": "CLIENT", "short_name": "OLD"]) }
        )
        vm.goToTarget()
        vm.selectTarget(candidate())
        await vm.preview()
        #expect(!vm.reboot.requiresReboot)
        vm.reviewForConfirmation()
        await vm.confirmAndApply()
        #expect(vm.outcome == .applied(rebooting: false))
    }

    // MARK: Verification-failure path

    @Test
    func `a node that drops the apply reports a verification failure`() async {
        let vm = makeVM(channel: BrokenChannel(["region": "EU_868", "role": "CLIENT"]))
        vm.goToTarget()
        vm.selectTarget(candidate())
        await vm.preview()
        vm.reviewForConfirmation()
        await vm.confirmAndApply()

        #expect(vm.step == .result)
        guard case let .verificationFailed(remaining) = vm.outcome else {
            Issue.record("expected a verification failure, got \(String(describing: vm.outcome))")
            return
        }
        #expect(!remaining.isEmpty)
        #expect(vm.outcome?.isSuccess == false)
    }

    // MARK: Reset

    @Test
    func `provisionAnother clears the target and result but keeps the template`() async {
        let vm = makeVM(channel: FakeChannel(["region": "EU_868", "role": "CLIENT"]))
        vm.goToTarget()
        vm.selectTarget(candidate())
        await vm.preview()
        vm.reviewForConfirmation()
        await vm.confirmAndApply()
        #expect(vm.outcome != nil)

        vm.provisionAnother()
        #expect(vm.step == .target)
        #expect(vm.selectedTarget == nil)
        #expect(vm.plan == nil)
        #expect(vm.outcome == nil)
        #expect(vm.draft.name == "Bay") // template preserved
    }

    @Test
    func `load populates targetable candidates from the injected source`() async {
        let seeded: [ProvisioningWorkflowViewModel.TargetCandidate] = [candidate(1), candidate(2)]
        let vm = ProvisioningWorkflowViewModel(
            channelFor: { _ in FakeChannel([:]) },
            loadCandidates: { seeded }
        )
        await vm.load()
        #expect(vm.candidates.count == 2)
    }
}
