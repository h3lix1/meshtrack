// SettingsRenderTests — the General + Alerts-config screens render headless. They
// are control-bespoke (custom step buttons, switches) so they produce a non-trivial
// bitmap under the `ImageRenderer` snapshot gate (see the snapshot-gotchas memo).

#if canImport(AppKit)
    @testable import App
    import AppKit
    import Domain
    import SwiftUI
    import Testing

    @Suite("Settings headless render")
    @MainActor
    struct SettingsRenderTests {
        private func renderedByteCount(_ view: some View, width: CGFloat, height: CGFloat) -> Int {
            let renderer = ImageRenderer(content: view.frame(width: width, height: height))
            renderer.scale = 1
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { return 0 }
            return png.count
        }

        @Test
        func `general settings renders`() {
            let viewModel = GeneralSettingsViewModel(gateway: InMemoryConfigGateway())
            viewModel.settings = AppSettings(themeID: "ember", telemetryRetentionDays: 45)
            #expect(renderedByteCount(
                GeneralSettingsView(viewModel: viewModel), width: 560, height: 620
            ) > 1000)
        }

        @Test
        func `alerts config renders with seeded rules`() async {
            let store = InMemoryAlertRuleStore([
                AlertRuleRecord(scope: .global, type: .batteryBelow, threshold: 20),
                AlertRuleRecord(scope: .global, type: .stale, threshold: 24),
                AlertRuleRecord(scope: .nodeClass(.mobile), type: .stale, threshold: 6),
                AlertRuleRecord(scope: .node(0xA1B2_C3D4), type: .voltageBelow, threshold: 3.4)
            ])
            let viewModel = AlertsConfigViewModel(rules: store)
            await viewModel.load()
            #expect(renderedByteCount(
                AlertsConfigView(viewModel: viewModel), width: 600, height: 700
            ) > 1000)
        }
    }
#endif
