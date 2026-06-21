// SettingsShellTests — the Settings window chrome + registry seam (Phase 8,
// T-Compose). Verifies the `SettingsModel` registry resolution every tab depends
// on, and that the bespoke `SettingsShellView` renders headless for each tab (the
// stock settings chrome would not — see the ImageRenderer snapshot gotchas memo).

@testable import App
import SwiftUI
import Testing

@Suite("Settings model registry")
@MainActor
struct SettingsModelRegistryTests {
    @Test
    func `an unregistered tab falls back to the placeholder, a registered one resolves`() {
        let model = SettingsModel()
        // Nothing registered yet → not registered for any tab.
        for tab in SettingsTab.allCases {
            #expect(!model.isRegistered(tab), "unexpected provider for \(tab.rawValue)")
        }
        model.register(.connection) { AnyView(Text("connection")) }
        #expect(model.isRegistered(.connection))
        #expect(!model.isRegistered(.general))
    }

    @Test
    func `register replaces a tab's provider (owning agents override placeholders)`() {
        let model = SettingsModel()
        model.register(.connection) { AnyView(Text("placeholder")) }
        model.register(.connection) { AnyView(Text("real provider")) }
        #expect(model.isRegistered(.connection))
        // Other tabs untouched.
        #expect(!model.isRegistered(.alerts))
    }

    @Test
    func `every tab exposes a title and an icon for the sidebar`() {
        for tab in SettingsTab.allCases {
            #expect(!tab.title.isEmpty)
            #expect(!tab.icon.isEmpty)
        }
    }
}

#if canImport(AppKit)
    import AppKit

    @Suite("Settings shell headless render")
    @MainActor
    struct SettingsShellRenderTests {
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

        @Test
        func `the settings shell renders a non-trivial bitmap for each tab`() {
            let model = SettingsModel()
            for tab in SettingsTab.allCases {
                model.register(tab) {
                    AnyView(Text("\(tab.title) content").foregroundStyle(.white))
                }
            }
            for tab in SettingsTab.allCases {
                let shell = SettingsShellView(model: model, tab: tab)
                #expect(renderedByteCount(shell) > 1000, "shell did not render for \(tab.rawValue)")
            }
        }

        @Test
        func `the shell renders even when a tab has no provider (placeholder path)`() {
            // Empty registry → the model's UnregisteredSettingsTab placeholder.
            let shell = SettingsShellView(model: SettingsModel(), tab: .connection)
            #expect(renderedByteCount(shell) > 1000)
        }
    }
#endif
