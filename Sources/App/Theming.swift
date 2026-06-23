// Theming — the live theme seam that makes a selected `Theme` actually change the
// app's chrome (Phase 8 fix). `Theme` (Observe/Theme.swift) is the pure model; this
// file adds the *application* layer:
//
//   • `ThemeController` — a `@MainActor @Observable` holder of the current `Theme`
//     that the composition root seeds and the General settings picker drives.
//   • `EnvironmentValues.appTheme` + the `.appTheme(_:)` modifier — so any view
//     (the shell chrome especially) reads the active theme from the environment
//     instead of hardcoding colours.
//
// The shell chrome (`AppShell`/`SidebarView`, `SettingsShellView`/`SettingsSidebar`)
// reads `@Environment(\.appTheme)` and tints from it, so switching a preset in
// Settings → General is immediately visible. Deep per-section theming of every
// analytics canvas is intentionally OUT OF SCOPE here — those views keep their own
// palettes; this targets the always-visible chrome so the change reads clearly.
//
// The lead seeds + injects the controller at the composition root — see the
// integration notes returned with this task.

import Observation
import SwiftUI

/// Holds the app's current `Theme` and applies changes to it. `@MainActor` because
/// it drives SwiftUI; `@Observable` so views re-render when `apply(_:)` swaps the
/// theme. The composition root creates one, seeds it from `AppSettings.themeID`,
/// injects it via `.appTheme(controller.theme)` (or the environment object), and the
/// General picker calls `apply(_:)` so a preset selection updates the live chrome.
@MainActor
@Observable
public final class ThemeController {
    /// The currently-applied theme. Reading this in a view body subscribes that view
    /// to theme changes.
    public private(set) var theme: Theme

    /// Create a controller seeded with `theme` (default: `.midnight`).
    public init(theme: Theme = .midnight) {
        self.theme = theme
    }

    /// Apply `theme` as the new current theme. Drives a live chrome update for every
    /// view reading `controller.theme` or the injected `\.appTheme` environment.
    public func apply(_ theme: Theme) {
        self.theme = theme
    }

    /// Resolve an `AppSettings.themeID` to a preset, falling back to `.midnight` for a
    /// `nil`/unknown id. The composition root uses this to seed the controller at
    /// launch.
    public static func resolve(themeID: String?) -> Theme {
        guard let themeID else { return .midnight }
        return Theme.presets.first { $0.id == themeID } ?? .midnight
    }
}

public extension EnvironmentValues {
    // The active app `Theme`. Defaults to `.midnight` so views render sensibly even
    // when nothing injected one (previews, the snapshot harness). Inject with
    // `.appTheme(_:)`.
    @Entry var appTheme: Theme = .midnight
}

public extension View {
    /// Inject `theme` as the active `\.appTheme` for this view and its descendants,
    /// and set SwiftUI's `.tint` to the theme accent so stock controls pick it up too.
    func appTheme(_ theme: Theme) -> some View {
        environment(\.appTheme, theme)
            .tint(theme.accentColor)
    }
}
