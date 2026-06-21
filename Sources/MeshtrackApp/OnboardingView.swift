// OnboardingView — the first-run / setup screen shown in the MAIN window when no
// broker has been configured (no saved `BrokerConfig` and no env fallback). It
// welcomes the operator and offers two paths instead of the old "connecting…/
// sample" fallback:
//
//   • "Set up connection" — opens the Settings window (⌘,) on the Connection tab
//     so the operator can enter a broker. Saving a connectable config makes the
//     app go live (the composition root re-applies config).
//   • "Explore with sample data" — drops into the sample-fed shell so the app is
//     useful before any broker is wired.
//
// Bespoke dark styling matching the app shell. No secrets here — there is nothing
// to surface yet.

import SwiftUI

/// The welcoming first-run setup view. Dark, centered, two clear actions.
struct OnboardingView: View {
    /// Open Settings on the Connection tab (the composition root opens the
    /// `Settings` scene via `openSettings`).
    let onSetUpConnection: () -> Void
    /// Continue into the sample-data shell to explore the app.
    let onExploreSample: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 22) {
                header
                actions
            }
            .frame(maxWidth: 520)
            .padding(40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.03, green: 0.04, blue: 0.10))
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 46))
                .foregroundStyle(.cyan)
            Text("Welcome to Meshtrack")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
            Text("Monitor your Meshtastic fleet over MQTT — nodes on a map, "
                + "live traffic, telemetry history, and movement/silence/battery alerts.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Connect a broker to go live. Your credentials stay in the Keychain "
                + "and are never logged.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button(action: onSetUpConnection) {
                Label("Set up connection", systemImage: "gearshape")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.cyan.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.cyan)
            }
            .buttonStyle(.plain)

            Button(action: onExploreSample) {
                Label("Explore with sample data", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)

            Text("You can open Settings anytime with ⌘,")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }
}

/// The connection status pill shown in the shell: a colored dot + label, with the
/// broker host when connecting/connected. NEVER shows credentials.
struct ConnectionStatusBadge: View {
    let status: LiveConnectionStatus

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.white.opacity(0.06), in: Capsule())
    }

    private var color: Color {
        switch status {
        case .offline: .gray
        case .connecting: .yellow
        case .connected: .green
        }
    }

    private var label: String {
        switch status {
        case .offline: "Offline"
        case let .connecting(host): "Connecting · \(host)"
        case let .connected(host): "Connected · \(host)"
        }
    }
}
