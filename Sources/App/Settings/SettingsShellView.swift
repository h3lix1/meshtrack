// SettingsShellView — the Settings window's chrome (Phase 8). A bespoke dark
// sidebar of `SettingsTab.allCases` plus a content container that renders
// `SettingsModel.view(for:)` for the selected tab. Bespoke (not the stock
// `TabView`/`Form` settings layout) for full dark-theme control and snapshot
// fidelity — the same reasoning as `AppShell` (see the ImageRenderer snapshot
// gotchas memo: stock settings chrome renders poorly headless).
//
// The macOS `Settings { }` scene in the MeshtrackApp executable hosts this view,
// which auto-binds ⌘,. The shell owns only chrome + selection; each tab's content
// comes from the `SettingsModel` registry, so content providers stay in their own
// files and this view never edits a central switch.

import SwiftUI

/// The Settings window: a styled sidebar (left) + the selected tab's content
/// (right), driven by a `SettingsModel`. Selection state lives here; content is
/// resolved from the registry so this view is agnostic to which tabs are wired.
public struct SettingsShellView: View {
    @Environment(\.appTheme) private var theme
    private let model: SettingsModel
    @State private var tab: SettingsTab

    /// - Parameters:
    ///   - model: the tab registry to resolve content from.
    ///   - tab: the initially-selected tab (default `.connection`, the first run
    ///     destination from onboarding).
    public init(model: SettingsModel, tab: SettingsTab = .connection) {
        self.model = model
        _tab = State(initialValue: tab)
    }

    public var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selected: $tab)
            Divider().overlay(Color.white.opacity(0.06))
            detail
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(theme.backgroundColor)
        .tint(theme.accentColor)
    }

    /// The scrolling detail pane: any tab taller than the window scrolls (the sidebar
    /// stays fixed). A `GeometryReader` measures the viewport so short tabs still fill
    /// it (`minHeight`) and paint to the bottom, while tall tabs grow past it and scroll.
    private var detail: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                model.view(for: tab)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: proxy.size.height,
                        alignment: .topLeading
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.backgroundColor)
    }
}

/// The left rail: an app header plus one row per `SettingsTab`, in registry order.
struct SettingsSidebar: View {
    @Environment(\.appTheme) private var theme
    @Binding var selected: SettingsTab

    /// A touch lighter than the canvas so the rail reads as a distinct surface across
    /// themes (derived from the theme background, matching `SidebarView`).
    private var sidebarBackground: Color {
        let background = theme.background
        return Color(
            .sRGB,
            red: min(1, background.red + 0.02),
            green: min(1, background.green + 0.02),
            blue: min(1, background.blue + 0.05),
            opacity: background.opacity
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                Image(systemName: "gearshape.fill").foregroundStyle(theme.accentColor)
                Text("Settings").font(.title2.bold()).foregroundStyle(.white)
            }
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 14)

            ForEach(SettingsTab.allCases) { item in
                Button {
                    selected = item
                } label: {
                    SettingsSidebarRow(tab: item, isSelected: selected == item, accent: theme.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
            Spacer()
        }
        .frame(width: 200)
        .background(sidebarBackground)
    }
}

/// One sidebar row: icon + title, highlighted when selected (theme accent, matching
/// the main shell).
struct SettingsSidebarRow: View {
    let tab: SettingsTab
    let isSelected: Bool
    let accent: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tab.icon).frame(width: 20)
            Text(tab.title).font(.system(size: 13, weight: .medium))
            Spacer()
        }
        .padding(.horizontal, 13).padding(.vertical, 9)
        .background(
            isSelected ? accent.opacity(0.16) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .foregroundStyle(isSelected ? accent : .white.opacity(0.65))
    }
}

#if DEBUG
    /// A demo `SettingsModel` whose General tab shows a tall, scrolling stand-in so the
    /// preview exercises both the scroll fix and the themed chrome without the real
    /// (gateway-backed) settings screens.
    @MainActor private func previewSettingsModel() -> SettingsModel {
        let model = SettingsModel()
        for tab in SettingsTab.allCases {
            model.register(tab) {
                AnyView(
                    VStack(alignment: .leading, spacing: 14) {
                        Text(tab.title).font(.title.bold())
                        ForEach(0 ..< 18, id: \.self) { row in
                            Text("Preference row \(row + 1)")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .padding(24)
                    .foregroundStyle(.white)
                )
            }
        }
        return model
    }

    // Two themes side by side: switching a preset in Settings → General re-tints this
    // chrome (sidebar background, accent, selection), and the tall content scrolls.
    #Preview("Settings shell — two themes") {
        HStack(spacing: 0) {
            SettingsShellView(model: previewSettingsModel(), tab: .general)
                .appTheme(.midnight)
            SettingsShellView(model: previewSettingsModel(), tab: .general)
                .appTheme(.ember)
        }
        .frame(width: 1480, height: 560)
        .preferredColorScheme(.dark)
    }
#endif
