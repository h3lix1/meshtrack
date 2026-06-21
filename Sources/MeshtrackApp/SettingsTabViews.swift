// SettingsTabViews — the settings-tab content this executable owns: the About tab
// and bespoke placeholders for the tabs other agents own (Connection / Channels /
// General / Alerts), so the Settings window renders end-to-end before those tabs
// are integrated.
//
// LEAD: at integration the owning agents replace the placeholders by registering
// their real providers (`settingsModel.register(.tab) { … }`). See
// `MeshtrackApp.registerSettingsTabs`.

import App
import SwiftUI

/// A dark, informative placeholder for a settings tab whose real content is owned
/// by another agent and not yet integrated. Distinct from the `App` library's
/// `UnregisteredSettingsTab` (which means "nobody registered anything") — this one
/// is a deliberate, app-styled stand-in.
struct PlaceholderSettingsTab: View {
    let tab: SettingsTab

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: tab.icon).font(.system(size: 38)).foregroundStyle(.cyan.opacity(0.8))
            Text(tab.title).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
            Text(blurb).font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var blurb: String {
        switch tab {
        case .connection:
            "Broker host, port, TLS, credentials, and subscribe topics. "
                + "Saving a connectable broker takes the app live."
        case .channels:
            "Channels and PSKs (Keychain-stored). Up to 20 MQTT / 7 local channels."
        case .general:
            "Refresh cadence, units, retention, notifications, launch-at-login, auto-connect."
        case .alerts:
            "Movement, silence, and battery rules with per-node and class overrides."
        case .about:
            "About Meshtrack."
        }
    }
}

/// The About tab — owned by this composition root. Static, no secrets.
struct AboutSettingsTab: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 44)).foregroundStyle(.cyan)
            Text("Meshtrack").font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
            Text("Native macOS monitoring + control for Meshtastic fleets.")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Text("Credentials and channel keys live in the Keychain and are never logged.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
