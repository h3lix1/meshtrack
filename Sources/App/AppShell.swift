// AppShell — the top-level window: a styled sidebar + the section content. Custom
// (not NavigationSplitView) for full dark-theme control and deterministic
// snapshots. Sections: Network (the hero map), Nodes, Telemetry, Alerts, Fleet.

import SwiftUI

public enum AppSection: String, CaseIterable, Identifiable {
    case network, nodes, packets, telemetry, alerts, health, fleet
    public var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .network: "Network"
        case .nodes: "Nodes"
        case .packets: "Packets"
        case .telemetry: "Telemetry"
        case .alerts: "Alerts"
        case .health: "Health"
        case .fleet: "Fleet Config"
        }
    }

    var icon: String {
        switch self {
        case .network: "point.3.connected.trianglepath.dotted"
        case .nodes: "dot.radiowaves.left.and.right"
        case .packets: "doc.text.magnifyingglass"
        case .telemetry: "chart.xyaxis.line"
        case .alerts: "bell.badge"
        case .health: "waveform.path.ecg"
        case .fleet: "slider.horizontal.3"
        }
    }
}

/// The top-level shell. Each `AppSection` delegates to a view resolved from the
/// `AppModel` registry, so feature streams add sections by registering a provider
/// (never editing this switch). The sample-data path builds a default `AppModel`.
public struct RootView: View {
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
        .background(Color(red: 0.03, green: 0.04, blue: 0.10))
        .environment(model)
    }
}

struct SidebarView: View {
    @Binding var section: AppSection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.cyan)
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
                        section == item ? Color.cyan.opacity(0.16) : .clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .foregroundStyle(section == item ? Color.cyan : .white.opacity(0.65))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
            Spacer()
        }
        .frame(width: 210)
        .background(Color(red: 0.05, green: 0.06, blue: 0.15))
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
