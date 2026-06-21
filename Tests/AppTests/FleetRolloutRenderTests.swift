// FleetRolloutRenderTests — proves the bespoke fleet-rollout views render under the
// headless ImageRenderer gate (no stock controls, no MapKit), so they survive the
// snapshot harness deterministically. We render the view across the rollout
// lifecycle (previewed, mid-rollout, failed-and-halted) and assert a non-trivial
// PNG comes back.

#if canImport(AppKit)
    @testable import App
    import AppKit
    import Provisioning
    import SwiftUI
    import Testing

    @Suite("Fleet rollout headless render")
    @MainActor
    struct FleetRolloutRenderTests {
        private let template = NodeTemplate(
            name: "fleet-std", region: "US", role: "CLIENT", positionPrecisionBits: 14
        )

        /// Render `view` headlessly and return the PNG byte count (0 on failure).
        private func renderedByteCount(_ view: some View) -> Int {
            let renderer = ImageRenderer(content: view.frame(width: 760, height: 520))
            renderer.scale = 1
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { return 0 }
            return png.count
        }

        private func member(_ num: Int64) -> FleetMember {
            FleetMember(nodeNum: num, context: NamingContext(id: "!\(String(num, radix: 16))"))
        }

        private func viewModel() -> FleetRolloutViewModel {
            FleetRolloutViewModel(
                channelFor: { _ in PreviewChannel() },
                template: template,
                members: [member(1), member(2), member(3)],
                names: [1: "BASE", 2: "RELAY-N", 3: "WEST"]
            )
        }

        @Test
        func `the rollout view renders with pending nodes`() {
            #expect(renderedByteCount(FleetRolloutView(viewModel: viewModel())) > 1000)
        }

        @Test
        func `the rollout view renders the previewed diff`() async {
            let vm = viewModel()
            await vm.preview()
            #expect(renderedByteCount(FleetRolloutView(viewModel: vm)) > 1000)
        }

        @Test
        func `individual rows render across every status`() {
            let statuses: [FleetRolloutViewModel.NodeStatus] = [
                .pending, .applying, .verified, .noChange, .failed("verification failed")
            ]
            for status in statuses {
                let row = FleetRolloutViewModel.Row(
                    member: member(7),
                    name: "NODE-7",
                    status: status,
                    changes: [ConfigChange(field: "region", from: "EU_868", to: "US")]
                )
                #expect(
                    renderedByteCount(FleetRolloutRowView(row: row)) > 0,
                    "row \(status) rendered nothing"
                )
            }
        }

        @Test
        func `the bespoke controls render`() {
            #expect(renderedByteCount(FleetActionButton(
                title: "Roll Out",
                systemImage: "play.fill",
                tint: .green
            ) {}) > 0)
            #expect(renderedByteCount(HaltBadge(on: true)) > 0)
            #expect(renderedByteCount(HaltBadge(on: false)) > 0)
        }
    }

    /// A trivial admin channel for render fixtures (its behaviour isn't exercised here).
    private struct PreviewChannel: AdminChannel {
        func currentConfig() -> [String: String] {
            ["region": "EU_868"]
        }

        func apply(_: [ConfigChange]) {}
    }
#endif
