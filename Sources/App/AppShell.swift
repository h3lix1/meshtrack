// AppShell — the top-level window: a styled sidebar + the section content. Custom
// (not NavigationSplitView) for full dark-theme control and deterministic
// snapshots. Sections: Network (the hero map), Nodes, Telemetry, Alerts, Fleet.

import SwiftUI

public enum AppSection: String, CaseIterable, Identifiable {
    case network, nodes, telemetry, alerts, fleet
    public var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .network: "Network"
        case .nodes: "Nodes"
        case .telemetry: "Telemetry"
        case .alerts: "Alerts"
        case .fleet: "Fleet Config"
        }
    }

    var icon: String {
        switch self {
        case .network: "point.3.connected.trianglepath.dotted"
        case .nodes: "dot.radiowaves.left.and.right"
        case .telemetry: "chart.xyaxis.line"
        case .alerts: "bell.badge"
        case .fleet: "slider.horizontal.3"
        }
    }
}

public struct RootView: View {
    @State private var section: AppSection = .network
    public let nodes: [NetworkNode]
    public let traces: [PacketTrace]

    public let live: Bool

    public init(nodes: [NetworkNode], traces: [PacketTrace], live: Bool = true) {
        self.nodes = nodes
        self.traces = traces
        self.live = live
    }

    public init(section: AppSection, nodes: [NetworkNode], traces: [PacketTrace], live: Bool = false) {
        _section = State(initialValue: section)
        self.nodes = nodes
        self.traces = traces
        self.live = live
    }

    public var body: some View {
        HStack(spacing: 0) {
            SidebarView(section: $section)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1100, minHeight: 720)
        .background(Color(red: 0.03, green: 0.04, blue: 0.10))
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case .network:
            if live {
                LiveNetworkScreen(nodes: nodes, traces: traces)
            } else {
                DashboardView(nodes: nodes, traces: traces, clock: 1.6)
            }
        case .nodes: NodesView(nodes: nodes)
        case .telemetry: TelemetryChartView(series: SampleNetwork.telemetry)
        case .alerts: AlertsView(alerts: SampleNetwork.alerts)
        case .fleet: FleetConfigView(rows: SampleNetwork.rollout)
        }
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
