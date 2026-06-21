// AlertsView — the alert feed (firing / acknowledged / resolved). Renders over the
// RuleEngine alert state; here driven by sample data for snapshots.

import SwiftUI

public struct AlertDisplay: Identifiable, Sendable {
    public enum State: Sendable, Equatable { case firing, acknowledged, resolved }

    public let id = UUID()
    public let type: String
    public let nodeName: String
    public let detail: String
    public let state: State

    public init(type: String, nodeName: String, detail: String, state: State) {
        self.type = type
        self.nodeName = nodeName
        self.detail = detail
        self.state = state
    }
}

public struct AlertsView: View {
    public let alerts: [AlertDisplay]
    public init(alerts: [AlertDisplay]) {
        self.alerts = alerts
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(alerts) { AlertRow(alert: $0) }
            }
            .padding(20)
        }
        .background(Color(red: 0.03, green: 0.04, blue: 0.10))
    }
}

struct AlertRow: View {
    let alert: AlertDisplay

    private var color: Color {
        switch alert.state {
        case .firing: .red
        case .acknowledged: .orange
        case .resolved: .green
        }
    }

    private var icon: String {
        switch alert.state {
        case .firing: "exclamationmark.triangle.fill"
        case .acknowledged: "hand.raised.fill"
        case .resolved: "checkmark.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundStyle(color).font(.title3).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.type).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text(alert.detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(alert.nodeName).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
            Text(String(describing: alert.state).uppercased())
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(color.opacity(0.18), in: Capsule())
                .foregroundStyle(color)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            Rectangle().fill(color).frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }
}
