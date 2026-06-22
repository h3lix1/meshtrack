// TrafficRenderTests — proves the bespoke Port-numbers + Largest-offenders screens
// render under the headless ImageRenderer gate (no stock List/ScrollView/Chart), so
// they survive the snapshot harness deterministically.

#if canImport(AppKit)
    @testable import App
    import AppKit
    import SwiftUI
    import Testing

    @Suite("Traffic analytics headless render")
    @MainActor
    struct TrafficRenderTests {
        private func renderedByteCount(
            _ view: some View,
            width: CGFloat = 1000,
            height: CGFloat = 640
        ) -> Int {
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
        func `the port-numbers section renders a non-trivial bitmap headless`() {
            let bytes = renderedByteCount(PortStatsSection(viewModel: .sample()))
            #expect(bytes > 1000, "section rendered only \(bytes) bytes")
        }

        @Test
        func `the largest-offenders section renders a non-trivial bitmap headless`() {
            let bytes = renderedByteCount(OffendersSection(viewModel: .sample()))
            #expect(bytes > 1000, "section rendered only \(bytes) bytes")
        }

        @Test
        func `empty states render without crashing`() {
            #expect(renderedByteCount(
                PortStatsView(rows: [], totalReceptions: 0, totalDistinctPackets: 0)
            ) > 0)
            #expect(renderedByteCount(OffendersView(rows: [], totalReceptions: 0)) > 0)
        }
    }
#endif
