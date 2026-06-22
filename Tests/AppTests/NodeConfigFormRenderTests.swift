// NodeConfigFormRenderTests — proves the broad per-node config form + favorites UI
// render under the headless ImageRenderer gate (Phase 10). The detail view now
// exposes the full config surface in collapsible bespoke sections (no stock
// Toggle/Picker/DisclosureGroup) plus the favorite ☆ / ignore action; we render it
// armed, disarmed, and favourited and assert a non-trivial PNG comes back.

#if canImport(AppKit)
    @testable import App
    import AppKit
    import Domain
    import Provisioning
    import SwiftUI
    import Testing

    @Suite("Node config form headless render (Phase 10)")
    @MainActor
    struct NodeConfigFormRenderTests {
        private func renderedByteCount(_ view: some View) -> Int {
            let renderer = ImageRenderer(content: view.frame(width: 460, height: 800))
            renderer.scale = 1
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { return 0 }
            return png.count
        }

        private func entry() -> NodeDirectoryEntry {
            NodeDirectoryEntry(
                nodeNum: 0xAABB_CCDD,
                hexID: "!aabbccdd",
                name: "BASE-1",
                nodeClass: .gateway,
                role: .gateway,
                isMine: true,
                isManaged: true,
                lastHeard: Instant(nanosecondsSinceEpoch: 0)
            )
        }

        @Test
        func `the broad directory detail renders disarmed`() {
            #expect(renderedByteCount(NodeDirectoryDetailView(entry: entry())) > 1000)
        }

        @Test
        func `the broad directory detail renders armed with sections expanded`() {
            let view = NodeDirectoryDetailView(
                entry: entry(),
                baseline: ["region": "US", "mqtt_enabled": "true"],
                armedForPreview: true,
                expandedSections: ["LoRa", "Device", "Modules", "Security"]
            )
            #expect(renderedByteCount(view) > 1000)
        }

        @Test
        func `the directory detail renders as a favourite`() {
            #expect(renderedByteCount(NodeDirectoryDetailView(entry: entry(), isFavorite: true)) > 1000)
        }

        @Test
        func `the bespoke config controls render across states`() throws {
            let form = NodeConfigFormState(baseline: ["region": "US"])
            let section = try #require(NodeConfigForm.sections.first { $0.title == "LoRa" })
            for armed in [true, false] {
                let view = NodeConfigSectionView(
                    section: section,
                    form: form,
                    armed: armed,
                    isExpanded: true,
                    onToggleExpand: {}
                )
                #expect(renderedByteCount(view) > 0, "LoRa section armed=\(armed) rendered nothing")
            }
            #expect(renderedByteCount(ConfigTogglePill(isOn: true, enabled: true) {}) > 0)
            #expect(renderedByteCount(ConfigTogglePill(isOn: false, enabled: false) {}) > 0)
        }

        @Test
        func `the simple node detail renders with the favorite action`() {
            let node = NetworkNode(
                id: 0x1234,
                name: "NODE-1",
                position: GeoPoint(latitude: 37.77, longitude: -122.41),
                hopsFromGateway: 2,
                batteryPercent: 84,
                isGateway: false
            )
            #expect(renderedByteCount(NodeDetailView(node: node, isFavorite: true)) > 1000)
        }
    }
#endif
