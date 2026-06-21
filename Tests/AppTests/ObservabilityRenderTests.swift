// ObservabilityRenderTests — proves the bespoke-Canvas observability dashboard
// renders under the headless ImageRenderer gate (no stock controls, no Charts),
// so it survives the snapshot harness deterministically.

#if canImport(AppKit)
    @testable import App
    import AppKit
    import SwiftUI
    import Testing

    @Suite("Observability headless render")
    @MainActor
    struct ObservabilityRenderTests {
        private func renderedByteCount(_ view: some View) -> Int {
            let renderer = ImageRenderer(content: view.frame(width: 760, height: 620))
            renderer.scale = 1
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { return 0 }
            return png.count
        }

        @Test
        func `healthy and degraded dashboards render non-trivial bitmaps`() {
            #expect(renderedByteCount(IngestHealthView(viewModel: ObservabilityPreviewData.healthy())) > 1000)
            #expect(renderedByteCount(IngestHealthView(viewModel: ObservabilityPreviewData.degraded())) > 1000)
        }

        @Test
        func `empty dashboard and sparkline still render`() {
            #expect(renderedByteCount(IngestHealthView(viewModel: ObservabilityViewModel())) > 0)
            #expect(renderedByteCount(ThroughputSparkline(samples: [])) > 0)
            #expect(renderedByteCount(ThroughputSparkline(samples: [1, 2, 3])) > 0)
        }
    }
#endif
