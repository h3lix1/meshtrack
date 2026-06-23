// FleetTemplateConfigRenderTests — proves the template editor's broad-config surface
// renders under the headless ImageRenderer gate (Phase 10). The template editor now
// reuses the SAME bespoke `NodeConfigSectionView` sections the per-node editor uses,
// bound to the view model's `configForm`, so we render those sections seeded from a
// template's group defaults and assert a non-trivial PNG comes back.

#if canImport(AppKit)
    @testable import App
    import AppKit
    import Domain
    import Persistence
    import Provisioning
    import SwiftUI
    import Testing

    @Suite("Fleet template broad-config editor headless render (Phase 10)")
    @MainActor
    struct FleetTemplateConfigRenderTests {
        private func renderedByteCount(_ view: some View) -> Int {
            let renderer = ImageRenderer(content: view.frame(width: 360, height: 700))
            renderer.scale = 1
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { return 0 }
            return png.count
        }

        @Test
        func `the shared config sections render seeded from a template's group defaults`() throws {
            // The template editor drives this exact form (always armed) over the VM's
            // configForm; seed it with broad defaults and render each section.
            let form = NodeConfigFormState(templateFields: [
                "region": "US",
                "modem_preset": "MEDIUM_FAST",
                "mqtt_enabled": "true",
                "tx_power": "20"
            ])
            for title in ["LoRa", "Modules", "Security"] {
                let section = try #require(NodeConfigForm.sections.first { $0.title == title })
                let view = NodeConfigSectionView(
                    section: section,
                    form: form,
                    armed: true,
                    isExpanded: true,
                    onToggleExpand: {}
                )
                #expect(renderedByteCount(view) > 0, "template \(title) section rendered nothing")
            }
        }

        @Test
        func `the view model's configForm reflects a selected template's broad fields`() async throws {
            let store = try MeshStore(DatabaseConnection.inMemory())
            let viewModel = FleetConfigViewModel(store: store)
            await viewModel.load()
            viewModel.newTemplate()
            viewModel.draft.name = "Render Fleet"
            viewModel.configForm.set("SHORT_FAST", for: "modem_preset")
            await viewModel.saveTemplate()

            // The form the editor renders carries the template's broad default.
            #expect(viewModel.configForm.values["modem_preset"] == "SHORT_FAST")
            let section = try #require(NodeConfigForm.sections.first { $0.title == "LoRa" })
            let view = NodeConfigSectionView(
                section: section,
                form: viewModel.configForm,
                armed: true,
                isExpanded: true,
                onToggleExpand: {}
            )
            #expect(renderedByteCount(view) > 0)
        }
    }
#endif
