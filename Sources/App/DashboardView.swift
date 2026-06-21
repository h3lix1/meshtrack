// DashboardView — the network map framed by a glassy HUD: a title/live badge, a
// fleet stats row, a packet-colour legend, and the hop-duration control. This is
// the centerpiece screen. `clock` is fixed for snapshots; LiveNetworkMap drives it
// continuously in the running app.

import SwiftUI

public struct DashboardView: View {
    public let nodes: [NetworkNode]
    public let traces: [PacketTrace]
    public var clock: Double

    public init(nodes: [NetworkNode], traces: [PacketTrace], clock: Double = 1.6) {
        self.nodes = nodes
        self.traces = traces
        self.clock = clock
    }

    private var gatewayCount: Int {
        nodes.count(where: \.isGateway)
    }

    private var lowBatteryCount: Int {
        nodes.count { ($0.batteryPercent ?? 100) < 20 }
    }

    public var body: some View {
        ZStack {
            NetworkMapView(nodes: nodes, traces: traces, clock: clock)
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
            .padding(20)
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            HStack(spacing: 10) {
                Circle().fill(.green).frame(width: 9, height: 9)
                    .shadow(color: .green, radius: 5)
                Text("MESHTRACK").font(.system(size: 18, weight: .heavy)).tracking(2)
                    .foregroundStyle(.white)
                Text("LIVE").font(.system(size: 11, weight: .bold)).foregroundStyle(.green)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            Spacer()
            HStack(spacing: 12) {
                stat("\(nodes.count)", "NODES", .cyan)
                stat("\(gatewayCount)", "GATEWAYS", .mint)
                stat("\(traces.count)", "IN FLIGHT", .yellow)
                stat("\(lowBatteryCount)", "LOW BATT", lowBatteryCount > 0 ? .red : .secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(color)
            Text(label).font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
        }
    }

    private var bottomBar: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ACTIVE PACKETS").font(.system(size: 9, weight: .bold)).tracking(1)
                    .foregroundStyle(.secondary)
                ForEach(traces) { trace in
                    HStack(spacing: 8) {
                        Circle().fill(trace.color).frame(width: 8, height: 8)
                            .shadow(color: trace.color, radius: 3)
                        Text(String(format: "!%08x", trace.id)).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                        Text("\(trace.hops) hops").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("HOP-NORMALISED ANIMATION").font(.system(size: 9, weight: .bold)).tracking(1)
                    .foregroundStyle(.secondary)
                Text("shorter hops draw slower — every hop lands together")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
            }
            .padding(14).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}
