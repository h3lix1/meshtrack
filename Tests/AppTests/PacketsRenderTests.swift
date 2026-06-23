// PacketsRenderTests — proves the bespoke packet-inspector views (G6) render under
// the headless ImageRenderer gate (no stock List/ScrollView/TabView, no MapKit) so
// they survive the snapshot harness deterministically. Renders the master/detail
// section + the latency histogram and asserts a non-trivial PNG comes back.

#if canImport(AppKit)
    @testable import App
    import AppKit
    import Domain
    import SwiftUI
    import Testing

    @Suite("Packet inspector headless render")
    @MainActor
    struct PacketsRenderTests {
        private func renderedByteCount(
            _ view: some View,
            width: CGFloat = 920,
            height: CGFloat = 600
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
        func `the packet inspector section renders a non-trivial bitmap headless`() {
            let bytes =
                renderedByteCount(PacketInspectorSection(viewModel: PacketInspectorSample.viewModel()))
            #expect(bytes > 1000, "section rendered only \(bytes) bytes")
        }

        @Test
        func `the empty inspector renders the awaiting state without crashing`() {
            let vm = PacketInspectorViewModel(clock: InjectedClock())
            #expect(renderedByteCount(PacketInspectorSection(viewModel: vm)) > 0)
        }

        @Test
        func `the latency histogram renders with samples and when empty`() {
            let withData = LatencyHistogram(distribution: LatencyDistribution(millis: [
                50,
                120,
                200,
                80,
                300
            ]))
            #expect(renderedByteCount(withData, width: 300, height: 80) > 0)
            #expect(renderedByteCount(LatencyHistogram(distribution: .empty), width: 300, height: 80) > 0)
        }
    }
#endif
