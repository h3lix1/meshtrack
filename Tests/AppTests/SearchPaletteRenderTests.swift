// SearchPaletteRenderTests — the bespoke palette renders headless (with results,
// empty, and no-matches states).

#if canImport(AppKit)
    @testable import App
    import AppKit
    import SwiftUI
    import Testing

    @Suite("Search palette headless render")
    @MainActor
    struct SearchPaletteRenderTests {
        private func renderedByteCount(_ view: some View) -> Int {
            let renderer = ImageRenderer(content: view.frame(width: 680, height: 520))
            renderer.scale = 1
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { return 0 }
            return png.count
        }

        @Test
        func `palette renders results, empty and no-match states`() {
            #expect(renderedByteCount(SearchPaletteView(viewModel: SearchPreviewData.viewModel(query: "base"))) > 1000)
            #expect(renderedByteCount(SearchPaletteView(viewModel: SearchPreviewData.viewModel())) > 0)
            #expect(renderedByteCount(SearchPaletteView(viewModel: SearchPreviewData.viewModel(query: "zzz"))) > 0)
        }
    }
#endif
