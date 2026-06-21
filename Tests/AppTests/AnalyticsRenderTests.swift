// AnalyticsRenderTests — proves the bespoke-Canvas analytics views render under
// the headless ImageRenderer gate (no stock controls, no MapKit), so they survive
// the snapshot harness deterministically. We render each tab + the telemetry chart
// and assert a non-trivial PNG comes back.

#if canImport(AppKit)
    @testable import App
    import AppKit
    import Domain
    import Persistence
    import SwiftUI
    import Testing

    @Suite("Analytics headless render")
    @MainActor
    struct AnalyticsRenderTests {
        /// Render `view` headlessly and return the PNG byte count (0 on failure).
        private func renderedByteCount(_ view: some View) -> Int {
            let renderer = ImageRenderer(content: view.frame(width: 600, height: 420))
            renderer.scale = 1
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { return 0 }
            return png.count
        }

        @Test
        func `every node-analytics tab renders a non-trivial bitmap headless`() throws {
            let viewModel = try AnalyticsPreviewData.nodeAnalyticsViewModel()
            for tab in NodeAnalyticsTab.allCases {
                viewModel.tab = tab
                let bytes = renderedByteCount(NodeAnalyticsView(viewModel: viewModel))
                #expect(bytes > 1000, "tab \(tab.rawValue) rendered only \(bytes) bytes")
            }
        }

        @Test
        func `the bespoke canvas charts render with empty inputs too`() {
            // Empty inputs must still render (the "No data" / empty states), never crash.
            #expect(renderedByteCount(HistogramChart(bars: [])) > 0)
            #expect(renderedByteCount(PeerTopologyGraph(nodeName: "X", peers: [])) > 0)
            #expect(renderedByteCount(HourlyHeatmap(buckets: [])) > 0)
            #expect(renderedByteCount(PacketTypeBreakdown(counts: [])) > 0)
        }
    }
#endif
