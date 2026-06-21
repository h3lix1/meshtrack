// ThemeRenderTests — the theme editor renders headless. (It uses a stock
// ColorPicker, which renders imperfectly headless per the snapshot gotchas memo,
// but the bespoke layout around it still produces a non-trivial bitmap.)

#if canImport(AppKit)
    @testable import App
    import AppKit
    import SwiftUI
    import Testing

    @Suite("Theme editor headless render")
    @MainActor
    struct ThemeRenderTests {
        private func renderedByteCount(_ view: some View) -> Int {
            let renderer = ImageRenderer(content: view.frame(width: 620, height: 560))
            renderer.scale = 1
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { return 0 }
            return png.count
        }

        @Test
        func `theme editor renders for both presets`() {
            #expect(renderedByteCount(ThemeEditorView(viewModel: ThemeEditorViewModel(theme: .midnight))) > 1000)
            #expect(renderedByteCount(ThemeEditorView(viewModel: ThemeEditorViewModel(theme: .ember))) > 1000)
        }
    }
#endif
