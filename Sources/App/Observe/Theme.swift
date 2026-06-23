// Theme — the customizable app palette (G10 polish). A pure, Codable, Sendable
// model (accent / background / trace palette) plus presets. It is provided here
// for the shell to apply at integration; this stream does NOT wire it globally
// (that is the lead's job) — we ship the model, an editor, and a `#Preview`.

import SwiftUI

/// An RGBA colour as Codable, Sendable components in `0...1`, so a `Theme` can be
/// persisted (e.g. to defaults) without depending on `Color`'s archiving. Bridges
/// to/from SwiftUI `Color`.
public struct ThemeColor: Codable, Sendable, Equatable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var opacity: Double

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    /// The SwiftUI colour for this value.
    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }

    /// Common constants without importing AppKit colour names.
    public static let white = ThemeColor(red: 1, green: 1, blue: 1)
}

/// The full app theme. `accent` tints interactive/highlight chrome, `background`
/// is the canvas, and `tracePalette` is the ordered set the visualization cycles
/// through (alongside the per-packet hash hue) for multi-trace legibility.
public struct Theme: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var accent: ThemeColor
    public var background: ThemeColor
    public var tracePalette: [ThemeColor]

    public init(
        id: String,
        name: String,
        accent: ThemeColor,
        background: ThemeColor,
        tracePalette: [ThemeColor]
    ) {
        self.id = id
        self.name = name
        self.accent = accent
        self.background = background
        self.tracePalette = tracePalette
    }

    /// The accent as a SwiftUI colour.
    public var accentColor: Color {
        accent.color
    }

    /// The background as a SwiftUI colour.
    public var backgroundColor: Color {
        background.color
    }

    /// The trace palette as SwiftUI colours.
    public var traceColors: [Color] {
        tracePalette.map(\.color)
    }

    /// The trace colour for an index, cycling through the palette. Falls back to
    /// the accent for an empty palette.
    public func traceColor(_ index: Int) -> Color {
        guard !tracePalette.isEmpty else { return accentColor }
        return tracePalette[index % tracePalette.count].color
    }
}

/// Built-in presets the editor starts from.
public extension Theme {
    /// The default dark theme matching the existing sections.
    static let midnight = Theme(
        id: "midnight",
        name: "Midnight",
        accent: ThemeColor(red: 0, green: 0.78, blue: 0.92),
        background: ThemeColor(red: 0.03, green: 0.04, blue: 0.10),
        tracePalette: [
            ThemeColor(red: 0.0, green: 0.78, blue: 0.92),
            ThemeColor(red: 0.55, green: 0.36, blue: 0.96),
            ThemeColor(red: 0.96, green: 0.62, blue: 0.16),
            ThemeColor(red: 0.20, green: 0.84, blue: 0.45)
        ]
    )

    /// A warmer high-contrast alternative.
    static let ember = Theme(
        id: "ember",
        name: "Ember",
        accent: ThemeColor(red: 0.98, green: 0.45, blue: 0.20),
        background: ThemeColor(red: 0.08, green: 0.05, blue: 0.05),
        tracePalette: [
            ThemeColor(red: 0.98, green: 0.45, blue: 0.20),
            ThemeColor(red: 0.95, green: 0.78, blue: 0.10),
            ThemeColor(red: 0.90, green: 0.25, blue: 0.35),
            ThemeColor(red: 0.55, green: 0.85, blue: 0.95)
        ]
    )

    /// All built-in presets.
    static let presets: [Theme] = [.midnight, .ember]
}
