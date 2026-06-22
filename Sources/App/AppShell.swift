// AppShell — the top-level window: a styled sidebar + the section content. Custom
// (not NavigationSplitView) for full dark-theme control and deterministic
// snapshots. Sections: Network (the hero map), Nodes, Telemetry, Alerts, Fleet.

import SwiftUI

public enum AppSection: String, CaseIterable, Identifiable {
    case network, nodes, packets, telemetry, analytics, alerts, messages, health, fleet, provision
    public var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .network: "Network"
        case .nodes: "Nodes"
        case .packets: "Packets"
        case .telemetry: "Telemetry"
        case .analytics: "Analytics"
        case .alerts: "Alerts"
        case .messages: "Messages"
        case .health: "Health"
        case .fleet: "Fleet Config"
        case .provision: "Provision"
        }
    }

    var icon: String {
        switch self {
        case .network: "point.3.connected.trianglepath.dotted"
        case .nodes: "dot.radiowaves.left.and.right"
        case .packets: "doc.text.magnifyingglass"
        case .telemetry: "chart.xyaxis.line"
        case .analytics: "chart.bar.xaxis"
        case .alerts: "bell.badge"
        case .messages: "bubble.left.and.bubble.right"
        case .health: "waveform.path.ecg"
        case .fleet: "slider.horizontal.3"
        case .provision: "badge.plus.radiowaves.right"
        }
    }
}

/// The top-level shell. Each `AppSection` delegates to a view resolved from the
/// `AppModel` registry, so feature streams add sections by registering a provider
/// (never editing this switch). The sample-data path builds a default `AppModel`.
public struct RootView: View {
    @Environment(\.appTheme) private var theme
    @State private var section: AppSection
    @State private var model: AppModel

    /// The primary initializer: drive the shell from an `AppModel` (live or sample).
    public init(model: AppModel, section: AppSection = .network) {
        _model = State(initialValue: model)
        _section = State(initialValue: section)
    }

    /// Convenience: build a default (sample-fed) `AppModel` from nodes/traces.
    public init(nodes: [NetworkNode], traces: [PacketTrace], live: Bool = true) {
        self.init(model: AppModel(nodes: nodes, traces: traces, live: live))
    }

    /// Convenience used by the snapshot harness: pin the section and use the
    /// deterministic Canvas-only Network map (`live: false`).
    public init(section: AppSection, nodes: [NetworkNode], traces: [PacketTrace], live: Bool = false) {
        self.init(model: AppModel(nodes: nodes, traces: traces, live: live), section: section)
    }

    public var body: some View {
        HStack(spacing: 0) {
            SidebarView(section: $section)
            model.view(for: section).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1100, minHeight: 720)
        .background(theme.backgroundColor)
        .tint(theme.accentColor)
        .environment(model)
        // Let section views route the operator between sections (Finding 19): the node
        // directory's "Open analytics" / "Apply config" actions update the selection.
        .onAppear { model.onNavigate = { section = $0 } }
    }
}

struct SidebarView: View {
    @Environment(\.appTheme) private var theme
    @Binding var section: AppSection

    /// The sidebar sits a touch lighter than the canvas so the rail reads as a
    /// distinct surface across themes (derived from the theme background, not hardcoded).
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
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(theme.accentColor)
                Text("Meshtrack").font(.title2.bold()).foregroundStyle(.white)
            }
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 14)

            ForEach(AppSection.allCases) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.icon).frame(width: 20)
                        Text(item.title).font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(
                        section == item ? theme.accentColor.opacity(0.16) : .clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .foregroundStyle(section == item ? theme.accentColor : .white.opacity(0.65))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
            Spacer()
        }
        .frame(width: 210)
        .background(sidebarBackground)
    }
}

/// The network screen with a continuously-advancing animation clock (looping).
struct LiveNetworkScreen: View {
    let nodes: [NetworkNode]
    let traces: [PacketTrace]

    var body: some View {
        TimelineView(.animation) { timeline in
            let clock = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10)
            DashboardView(nodes: nodes, traces: traces, clock: clock)
        }
    }
}
