@testable import App
import Foundation
import Testing

@Suite("Theme model")
struct ThemeTests {
    @Test
    func `theme is codable round-trip`() throws {
        let original = Theme.ember
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Theme.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func `trace colour cycles through the palette`() {
        let theme = Theme.midnight
        let count = theme.tracePalette.count
        #expect(count >= 2)
        // The wrapping accessor cycles modulo the palette length.
        #expect(theme.traceColor(0) == theme.tracePalette[0].color)
        #expect(theme.traceColor(count) == theme.tracePalette[0].color)
        #expect(theme.traceColor(count + 1) == theme.tracePalette[1].color)
    }

    @Test
    func `empty palette falls back to the accent`() {
        let theme = Theme(
            id: "x", name: "X",
            accent: ThemeColor(red: 1, green: 0, blue: 0),
            background: .white,
            tracePalette: []
        )
        #expect(theme.traceColor(0) == theme.accentColor)
    }

    @Test
    func `presets are distinct identities`() {
        #expect(Theme.presets.count == 2)
        #expect(Set(Theme.presets.map(\.id)).count == 2)
    }

    @Test
    @MainActor
    func `applying a preset replaces the edited theme`() {
        let viewModel = ThemeEditorViewModel(theme: .midnight)
        #expect(viewModel.theme.id == "midnight")
        viewModel.apply(preset: .ember)
        #expect(viewModel.theme.id == "ember")
        #expect(viewModel.theme.accent == Theme.ember.accent)
    }

    @Test
    @MainActor
    func `palette add and remove mutate the edited theme`() {
        let viewModel = ThemeEditorViewModel(theme: .midnight)
        let initial = viewModel.theme.tracePalette.count
        viewModel.addTraceColor(ThemeColor(red: 0, green: 1, blue: 0))
        #expect(viewModel.theme.tracePalette.count == initial + 1)
        viewModel.removeTraceColor(at: 0)
        #expect(viewModel.theme.tracePalette.count == initial)
    }

    @Test
    @MainActor
    func `remove keeps at least one trace colour`() {
        let viewModel = ThemeEditorViewModel(theme: Theme(
            id: "solo", name: "Solo",
            accent: .white, background: .white,
            tracePalette: [ThemeColor(red: 1, green: 0, blue: 0)]
        ))
        viewModel.removeTraceColor(at: 0)
        #expect(viewModel.theme.tracePalette.count == 1)
    }

    @Test
    @MainActor
    func `remove ignores out-of-range index`() {
        let viewModel = ThemeEditorViewModel(theme: .midnight)
        let before = viewModel.theme.tracePalette
        viewModel.removeTraceColor(at: 99)
        #expect(viewModel.theme.tracePalette == before)
    }
}
