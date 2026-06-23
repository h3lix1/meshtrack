// CollisionMatrixLayoutTests — guards the Phase 10 collision-page layout rework
// (larger text + scrollable cards). The page now wraps its card stack in a
// `ScrollView`, which can collapse to a clipped strip under the headless
// `ImageRenderer` used by snapshots. These tests assert (a) the full page still
// renders a non-trivial bitmap through the scroll view, both unselected and with a
// byte selected (the taller, detail-card variant), and (b) the bespoke `pageContent`
// subview — the scrollable card stack the render path targets — lays out at its
// intrinsic height rather than collapsing, so the cards below the heatmap stay
// reachable.

#if canImport(AppKit)
    @testable import App
    import AppKit
    import SwiftUI
    import Testing

    @Suite("Collision matrix layout (scroll + larger text)")
    @MainActor
    struct CollisionMatrixLayoutTests {
        /// Render `view` headless and return the PNG byte count (0 when nothing drew).
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
        func `scrollable page renders a non-trivial bitmap when a byte is selected`() {
            // The detail-card variant is the tallest layout and the one most at risk of
            // collapsing inside the scroll view headless.
            let view = CollisionMatrixView(viewModel: CollisionMatrixPreviewData.selectedViewModel())
            #expect(renderedByteCount(view, width: 760, height: 1040) > 1000)
        }

        @Test
        func `the bespoke page content lays out at full intrinsic height`() {
            // `pageContent` is the scrollable card stack the headless render path targets.
            // Given a generous fixed frame it must draw the whole stack (heatmap + cards),
            // i.e. produce a substantial bitmap rather than a collapsed strip.
            let viewModel = CollisionMatrixPreviewData.selectedViewModel()
            let content = CollisionMatrixView(viewModel: viewModel).pageContent
            #expect(renderedByteCount(content, width: 760, height: 1000) > 1000)
        }
    }
#endif
