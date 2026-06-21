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
            model.view(for: tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(SettingsTheme.content)
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(SettingsTheme.content)
    }
}

/// Shared dark palette for the settings chrome, matching `AppShell`'s background
/// tones so the Settings window reads as the same app.
enum SettingsTheme {
    /// The deep-navy content background (matches `RootView`).
    static let content = Color(red: 0.03, green: 0.04, blue: 0.10)
    /// The slightly-lighter sidebar background (matches `SidebarView`).
    static let sidebar = Color(red: 0.05, green: 0.06, blue: 0.15)
}

/// The left rail: an app header plus one row per `SettingsTab`, in registry order.
struct SettingsSidebar: View {
    @Binding var selected: SettingsTab

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                Image(systemName: "gearshape.fill").foregroundStyle(.cyan)
                Text("Settings").font(.title2.bold()).foregroundStyle(.white)
            }
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 14)

            ForEach(SettingsTab.allCases) { item in
                Button {
                    selected = item
                } label: {
                    SettingsSidebarRow(tab: item, isSelected: selected == item)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
            Spacer()
        }
        .frame(width: 200)
        .background(SettingsTheme.sidebar)
    }
}

/// One sidebar row: icon + title, highlighted when selected (cyan, matching the
/// main shell).
struct SettingsSidebarRow: View {
    let tab: SettingsTab
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tab.icon).frame(width: 20)
            Text(tab.title).font(.system(size: 13, weight: .medium))
            Spacer()
        }
        .padding(.horizontal, 13).padding(.vertical, 9)
        .background(
            isSelected ? Color.cyan.opacity(0.16) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .foregroundStyle(isSelected ? Color.cyan : .white.opacity(0.65))
    }
}
