// ThemingTests — the live-theme seam (Phase 8 fix). Covers the `ThemeController`
// holder + id resolution, and (headless) that the scrolling, themed settings shell
// still renders a non-trivial bitmap under each preset (the snapshot gate the stock
// settings chrome would fail — see the ImageRenderer snapshot gotchas memo).

@testable import App
import SwiftUI
import Testing

@Suite("ThemeController")
@MainActor
struct ThemeControllerTests {
    @Test
    func `seeds with a theme and apply swaps the current theme`() {
        let controller = ThemeController(theme: .midnight)
        #expect(controller.theme.id == "midnight")
        controller.apply(.ember)
        #expect(controller.theme.id == "ember")
    }

    @Test
    func `resolve maps a themeID to a preset and falls back to midnight`() {
        #expect(ThemeController.resolve(themeID: "ember").id == "ember")
        #expect(ThemeController.resolve(themeID: "midnight").id == "midnight")
        // nil / unknown → the default preset.
        #expect(ThemeController.resolve(themeID: nil).id == "midnight")
        #expect(ThemeController.resolve(themeID: "nope").id == "midnight")
    }
}

#if canImport(AppKit)
    import AppKit

    @Suite("Themed settings shell headless render")
    @MainActor
    struct ThemedSettingsShellRenderTests {
        private func renderedByteCount(_ view: some View) -> Int {
            // Size tall so a scrolling tab still fills the rendered viewport.
            let renderer = ImageRenderer(content: view.frame(width: 760, height: 900))
            renderer.scale = 1
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { return 0 }
            return png.count
        }

        @Test
        func `the scrolling settings shell renders under each preset`() {
            let model = SettingsModel()
            for tab in SettingsTab.allCases {
                model.register(tab) {
                    AnyView(Text("\(tab.title) content").foregroundStyle(.white))
                }
            }
            for theme in Theme.presets {
                let shell = SettingsShellView(model: model, tab: .general).appTheme(theme)
                #expect(renderedByteCount(shell) > 1000, "shell did not render under \(theme.id)")
            }
        }
    }
#endif
