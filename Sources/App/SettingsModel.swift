// SettingsModel — the Settings window's tab registry (Phase 8 seam), mirroring
// `AppModel`. A single `@MainActor @Observable` object resolves each `SettingsTab`
// to its content view, so each settings screen is registered from its own file and
// the composition root never edits a central switch.
//
// The macOS `Settings { }` scene (in the MeshtrackApp executable) renders the tab
// selected in the sidebar via `view(for:)`.

import SwiftUI

/// The Settings window's tabs. Order here is the sidebar order.
public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case connection, channels, general, alerts, about
    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .connection: "Connection"
        case .channels: "Channels & Keys"
        case .general: "General"
        case .alerts: "Alerts"
        case .about: "About"
        }
    }

    public var icon: String {
        switch self {
        case .connection: "antenna.radiowaves.left.and.right"
        case .channels: "key.horizontal"
        case .general: "gearshape"
        case .alerts: "bell.badge"
        case .about: "info.circle"
        }
    }
}

/// Builds the content view for one `SettingsTab`.
public typealias SettingsTabProvider = @MainActor () -> AnyView

@MainActor
@Observable
public final class SettingsModel {
    @ObservationIgnored private var registry: [SettingsTab: SettingsTabProvider] = [:]

    public init() {}

    /// Register (or replace) the content provider for `tab`. Each settings screen
    /// registers itself from its own composition file — no central switch to edit.
    public func register(_ tab: SettingsTab, _ provider: @escaping SettingsTabProvider) {
        registry[tab] = provider
    }

    /// The content view for `tab`; a placeholder when nothing is registered yet.
    @ViewBuilder
    public func view(for tab: SettingsTab) -> some View {
        if let provider = registry[tab] {
            provider()
        } else {
            UnregisteredSettingsTab(tab: tab)
        }
    }

    /// Whether a provider is registered for `tab` (testing seam).
    func isRegistered(_ tab: SettingsTab) -> Bool {
        registry[tab] != nil
    }
}

/// Placeholder for a settings tab with no registered provider yet.
struct UnregisteredSettingsTab: View {
    let tab: SettingsTab

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: tab.icon).font(.largeTitle).foregroundStyle(.secondary)
            Text("\(tab.title) settings").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
