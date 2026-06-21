// ProvisioningWorkflowRenderTests — proves the bespoke provisioning workflow views
// render under the headless ImageRenderer gate (no stock controls / ScrollView), so
// they survive the snapshot harness deterministically. We render the view across
// every step of the flow (template → target → preview → confirm → result) and the
// individual components, asserting a non-trivial PNG comes back.

#if canImport(AppKit)
    @testable import App
    import AppKit
    import Provisioning
    import SwiftUI
    import Testing

    @Suite("Provisioning workflow headless render")
    @MainActor
    struct ProvisioningWorkflowRenderTests {
        private func renderedByteCount(_ view: some View) -> Int {
            let renderer = ImageRenderer(content: view.frame(width: 760, height: 560))
            renderer.scale = 1
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { return 0 }
            return png.count
        }

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

        private func candidate() -> ProvisioningWorkflowViewModel.TargetCandidate {
            ProvisioningWorkflowViewModel.TargetCandidate(
                nodeNum: 0x42, name: "BASE", hexID: "!00000042",
                shortName: "BASE", role: "CLIENT", isNewlyDiscovered: true
            )
        }

        private func viewModel() -> ProvisioningWorkflowViewModel {
            let seeded = candidate()
            return ProvisioningWorkflowViewModel(
                draft: TemplateDraft(name: "Bay", region: "US", role: "ROUTER"),
                channelFor: { _ in FakeChannel(["region": "EU_868", "role": "CLIENT"]) },
                loadCandidates: { [seeded] }
            )
        }

        @Test
        func `the template step renders`() {
            #expect(renderedByteCount(ProvisioningWorkflowView(viewModel: viewModel())) > 1000)
        }

        @Test
        func `the target step renders with candidates`() async {
            let vm = viewModel()
            await vm.load()
            vm.goToTarget()
            #expect(renderedByteCount(ProvisioningWorkflowView(viewModel: vm)) > 1000)
        }

        @Test
        func `the preview step renders the diff and reboot warning`() async {
            let vm = viewModel()
            await vm.load()
            vm.goToTarget()
            vm.selectTarget(candidate())
            await vm.preview()
            #expect(renderedByteCount(ProvisioningWorkflowView(viewModel: vm)) > 1000)
        }

        @Test
        func `the confirm step renders the gate`() async {
            let vm = viewModel()
            await vm.load()
            vm.goToTarget()
            vm.selectTarget(candidate())
            await vm.preview()
            vm.reviewForConfirmation()
            #expect(renderedByteCount(ProvisioningWorkflowView(viewModel: vm)) > 1000)
        }

        @Test
        func `the result step renders after a successful apply`() async {
            let vm = viewModel()
            await vm.load()
            vm.goToTarget()
            vm.selectTarget(candidate())
            await vm.preview()
            vm.reviewForConfirmation()
            await vm.confirmAndApply()
            #expect(renderedByteCount(ProvisioningWorkflowView(viewModel: vm)) > 1000)
        }

        @Test
        func `individual components render`() {
            #expect(renderedByteCount(StepChip(title: "Preview", state: .current)) > 0)
            #expect(renderedByteCount(StepChip(title: "Done", state: .done)) > 0)
            #expect(renderedByteCount(TargetRow(candidate: candidate(), selected: true) {}) > 0)
            #expect(renderedByteCount(DiffList(changes: [
                ConfigChange(field: "region", from: "EU_868", to: "US")
            ])) > 0)
            #expect(renderedByteCount(RebootWarning(fields: ["region", "role"])) > 0)
            #expect(renderedByteCount(ProvisioningButton(
                title: "Confirm", systemImage: "checkmark", tint: .green, enabled: true
            ) {}) > 0)
            // A disabled button still renders (dimmed).
            #expect(renderedByteCount(ProvisioningButton(
                title: "Next", systemImage: "arrow.right", tint: .cyan, enabled: false
            ) {}) > 0)
        }
    }
#endif
