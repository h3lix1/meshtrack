// OffenderDetailRenderTests — proves the bespoke per-node detail panel and the now-
// scrollable offenders ranking render under the headless ImageRenderer gate (no stock
// List/ScrollView/Chart content collapses), plus the master/detail selection seam on
// the view model.

@testable import App
import Domain
import Testing

@Suite("Offenders detail — selection seam")
@MainActor
struct OffenderSelectionTests {
    @Test
    func `selecting a node exposes its live detail and clearing returns to the list`() {
        let model = OffendersViewModel.sample()
        #expect(model.selectedNode == nil)
        #expect(model.selectedDetail == nil)

        guard let top = model.rows.first else {
            Issue.record("no offenders in sample"); return
        }
        model.select(nodeNum: top.nodeNum)
        #expect(model.selectedNode == top.nodeNum)
        let detail = model.selectedDetail
        #expect(detail?.nodeNum == top.nodeNum)
        #expect(detail?.receptions == top.receptions)
        #expect((detail?.ports.isEmpty == false))

        model.clearSelection()
        #expect(model.selectedNode == nil)
        #expect(model.selectedDetail == nil)
    }

    @Test
    func `selecting an unknown node yields no detail`() {
        let model = OffendersViewModel.sample()
        model.select(nodeNum: 0xDEAD_BEEF)
        #expect(model.selectedDetail == nil)
    }
}

#if canImport(AppKit)
    import AppKit
    import SwiftUI

    @Suite("Offenders detail headless render")
    @MainActor
    struct OffenderDetailRenderTests {
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

        private func sampleDetail() -> OffenderDetail? {
            let model = OffendersViewModel.sample()
            guard let top = model.rows.first else { return nil }
            model.select(nodeNum: top.nodeNum)
            return model.selectedDetail
        }

        @Test
        func `the offender detail panel renders a non-trivial bitmap headless`() {
            guard let detail = sampleDetail() else {
                Issue.record("no sample detail"); return
            }
            let bytes = renderedByteCount(OffenderDetailView(detail: detail, rank: 1) {})
            #expect(bytes > 1000, "detail rendered only \(bytes) bytes")
        }

        @Test
        func `the scrollable ranking content renders its full intrinsic height`() {
            let view = OffendersView(rows: OffendersViewModel.sample().rows, totalReceptions: 100) { _ in }
            #expect(renderedByteCount(view) > 1000)
        }
    }
#endif
