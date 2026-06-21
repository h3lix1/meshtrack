// CollisionMatrixRenderTests — the bespoke-Canvas heatmap renders headless.

#if canImport(AppKit)
    @testable import App
    import AppKit
    import SwiftUI
    import Testing

    @Suite("Collision matrix headless render")
    @MainActor
    struct CollisionMatrixRenderTests {
        private func renderedByteCount(_ view: some View) -> Int {
            let renderer = ImageRenderer(content: view.frame(width: 760, height: 720))
            renderer.scale = 1
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { return 0 }
            return png.count
        }

        @Test
        func `populated collision matrix renders a non-trivial bitmap`() {
            #expect(
                renderedByteCount(CollisionMatrixView(viewModel: CollisionMatrixPreviewData.viewModel())) >
                    1000
            )
        }

        @Test
        func `empty matrix and heatmap still render`() {
            #expect(renderedByteCount(CollisionMatrixView(viewModel: CollisionMatrixViewModel())) > 0)
            #expect(
                renderedByteCount(CollisionHeatmap(buckets: CollisionMatrix.analyse([]).lastByteBuckets)) >
                    0
            )
        }
    }
#endif
