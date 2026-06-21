// ThemeEditorView — a small theme customizer (G10 polish). Edits accent /
// background / trace palette of a `Theme` and exposes the result via
// `ThemeEditorViewModel.theme`, which the shell can observe + apply. This stream
// provides the model + editor + preview only; it does NOT install the theme
// globally (the lead wires it at integration).

import Observation
import SwiftUI

/// Holds the theme being edited. `@MainActor @Observable`; the editor binds to it,
/// and the shell reads `theme` to apply. Pure value-mutation logic (preset
/// selection, palette add/remove) is testable without SwiftUI.
@Observable
@MainActor
public final class ThemeEditorViewModel {
    /// The live theme the shell applies.
    public var theme: Theme

    public init(theme: Theme = .midnight) {
        self.theme = theme
    }

    /// The presets the picker offers.
    public let presets: [Theme] = Theme.presets

    /// Reset the edited theme to a preset (keeps the preset's identity).
    public func apply(preset: Theme) {
        theme = preset
    }

    /// Add a trace colour to the palette.
    public func addTraceColor(_ color: ThemeColor) {
        theme.tracePalette.append(color)
    }

    /// Remove the trace colour at `index` (no-op if out of range). Keeps at least
    /// one colour so the visualization always has a palette.
    public func removeTraceColor(at index: Int) {
        guard theme.tracePalette.indices.contains(index), theme.tracePalette.count > 1 else { return }
        theme.tracePalette.remove(at: index)
    }
}

/// The theme editor: preset chips, accent + background colour wells, and the trace
/// palette with add/remove, plus a small live preview swatch row.
public struct ThemeEditorView: View {
    @Bindable private var viewModel: ThemeEditorViewModel

    public init(viewModel: ThemeEditorViewModel) {
        _viewModel = Bindable(viewModel)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            presetRow
            colorWells
            paletteEditor
            preview
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(viewModel.theme.backgroundColor)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Theme").font(.title.bold()).foregroundStyle(.white)
            Text("customise the accent, background and trace palette")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PRESETS").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(viewModel.presets) { preset in
                    Button { viewModel.apply(preset: preset) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(preset.accentColor).frame(width: 10, height: 10)
                            Text(preset.name).font(.system(size: 12)).foregroundStyle(.white)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(
                            .white.opacity(viewModel.theme.id == preset.id ? 0.16 : 0.05),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var colorWells: some View {
        HStack(alignment: .top, spacing: 24) {
            ThemeColorWell(label: "ACCENT", color: $viewModel.theme.accent)
            ThemeColorWell(label: "BACKGROUND", color: $viewModel.theme.background)
        }
    }

    private var paletteEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TRACE PALETTE").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(Array(viewModel.theme.tracePalette.enumerated()), id: \.offset) { index, color in
                    Button { viewModel.removeTraceColor(at: index) } label: {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(color.color)
                            .frame(width: 34, height: 34)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.2)))
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                }
                Button { viewModel.addTraceColor(.white) } label: {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3]))
                        .frame(width: 34, height: 34)
                        .overlay(Image(systemName: "plus").foregroundStyle(.white.opacity(0.6)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PREVIEW").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(0..<6, id: \.self) { index in
                    Capsule()
                        .fill(viewModel.theme.traceColor(index))
                        .frame(width: 44, height: 8)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(viewModel.theme.backgroundColor, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(viewModel.theme.accentColor.opacity(0.4)))
        }
    }
}

/// A labelled colour well over a `ThemeColor` binding. Bespoke (no stock
/// `ColorPicker`, which crashes the headless `ImageRenderer`): a live swatch plus
/// three RGB sliders, all of which render deterministically.
private struct ThemeColorWell: View {
    let label: String
    @Binding var color: ThemeColor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 8)
                .fill(color.color)
                .frame(width: 120, height: 30)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.2)))
            channel("R", value: $color.red, tint: .red)
            channel("G", value: $color.green, tint: .green)
            channel("B", value: $color.blue, tint: .blue)
        }
        .frame(width: 200)
    }

    /// A bespoke 0…1 channel control: a fill-bar (no stock `Slider`, which renders
    /// badly headless) with −/+ step buttons.
    private func channel(_ name: String, value: Binding<Double>, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 12)
            Button { step(value, by: -0.1) } label: { stepLabel("minus") }.buttonStyle(.plain)
            ChannelBar(fraction: value.wrappedValue, tint: tint)
            Button { step(value, by: 0.1) } label: { stepLabel("plus") }.buttonStyle(.plain)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 30)
        }
    }

    private func stepLabel(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(.white.opacity(0.7))
            .frame(width: 14, height: 14)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
    }

    private func step(_ value: Binding<Double>, by delta: Double) {
        value.wrappedValue = min(1, max(0, value.wrappedValue + delta))
    }
}

/// A fixed-width 0…1 fill bar drawn with `Canvas` (no `GeometryReader`, which can
/// crash the headless `ImageRenderer` under concurrent renders).
private struct ChannelBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
            context.fill(track, with: .color(.white.opacity(0.10)))
            let clamped = min(1, max(0, fraction))
            let fillRect = CGRect(x: 0, y: 0, width: size.width * clamped, height: size.height)
            context.fill(Path(roundedRect: fillRect, cornerRadius: size.height / 2), with: .color(tint))
        }
        .frame(width: 80, height: 6)
    }
}

#if DEBUG
    #Preview("Theme editor — Midnight") {
        ThemeEditorView(viewModel: ThemeEditorViewModel(theme: .midnight))
            .frame(width: 620, height: 560)
    }

    #Preview("Theme editor — Ember") {
        ThemeEditorView(viewModel: ThemeEditorViewModel(theme: .ember))
            .frame(width: 620, height: 560)
    }
#endif
