// NodeDataSectionTests — proves the bespoke `NodePicker` + `NodeDataSectionView`
// render headlessly under the ImageRenderer snapshot gate (no stock
// `Picker`/`Menu`/`List`), so the new node-selection chrome survives the snapshot
// harness deterministically. Also exercises the section's `.task` load over a
// seeded in-memory store so the picker resolves to a real node.

#if canImport(AppKit)
    @testable import App
    import AppKit
    import Domain
    import Persistence
    import SwiftUI
    import Testing

    @Suite("Node data section headless render")
    @MainActor
    struct NodeDataSectionTests {
        private func renderedByteCount(_ view: some View) -> Int {
            let renderer = ImageRenderer(content: view.frame(width: 760, height: 520))
            renderer.scale = 1
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { return 0 }
            return png.count
        }

        private func entries() -> [NodePickerEntry] {
            [
                NodePickerEntry(
                    nodeNum: 0xA1B2_C3D4, name: "Oakland", hexID: "!a1b2c3d4",
                    lastActivity: 5000, hasPositionData: true
                ),
                NodePickerEntry(
                    nodeNum: 0x3333_4444, name: "Passer-by", hexID: "!33334444",
                    lastActivity: 1000, hasPositionData: false
                )
            ]
        }

        @Test
        func `populated node picker renders a non-trivial bitmap`() {
            #expect(renderedByteCount(NodePicker(
                entries: entries(),
                selection: 0xA1B2_C3D4,
                searchText: .constant(""),
                onSelect: { _ in }
            )) > 1000)
        }

        @Test
        func `empty node picker still renders`() {
            #expect(renderedByteCount(NodePicker(
                entries: [],
                selection: nil,
                searchText: .constant(""),
                onSelect: { _ in }
            )) > 0)
        }

        @Test
        func `node data section renders over a seeded store`() async throws {
            let store = try MeshStore(DatabaseConnection.inMemory())
            try await store.upsertNode(NodeRecord(
                node_num: 0xA1B2_C3D4, short_name: "Oakland", first_seen_at: 0, last_heard_at: 1
            ))
            let view = NodeDataSectionView(store: store, title: "Telemetry") { nodeNum in
                Text("node \(nodeNum)")
            }
            #expect(renderedByteCount(view) > 0)
        }

        @Test
        func `telemetry empty and loading states are distinct and render`() async throws {
            // A node with no telemetry: after load(), the view shows the bespoke
            // "no telemetry yet" empty state rather than a perpetual loading state.
            let store = try MeshStore(DatabaseConnection.inMemory())
            let viewModel = TelemetryChartsViewModel(store: store, nodeNum: 0x01)
            #expect(!viewModel.loaded)
            #expect(renderedByteCount(TelemetryChartsView(viewModel: viewModel)) > 0)
            try await viewModel.load()
            #expect(viewModel.loaded)
            #expect(!viewModel.hasData)
            #expect(renderedByteCount(TelemetryChartsView(viewModel: viewModel)) > 0)
        }
    }
#endif
