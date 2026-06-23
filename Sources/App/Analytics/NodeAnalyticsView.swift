// NodeAnalyticsView — the per-node analytics deep-dive (Phase 7 G4): a multi-tab
// dashboard over `NodeAnalyticsViewModel`. Five tabs — Signal (SNR/RSSI
// distribution), Hops (hop-count histogram), Peers (radial topology graph),
// Activity (24h heatmap), and Packet Types (per-MeshPort breakdown).
//
// Bespoke Canvas charts + a hand-rolled tab bar (no stock TabView/segmented
// control) so the whole view renders deterministically under the headless
// ImageRenderer snapshot gate.

import Domain
import Persistence
import SwiftUI

public struct NodeAnalyticsView: View {
    @State private var viewModel: NodeAnalyticsViewModel

    public init(viewModel: NodeAnalyticsViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            tabBar
            card { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AnalyticsTheme.background)
        .task { try? await viewModel.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(viewModel.nodeName ?? Self.hex(viewModel.nodeNum))
                .font(.title2.bold()).foregroundStyle(.white)
            Text("\(viewModel.observationCount) receptions · \(viewModel.packetCount) packets")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(NodeAnalyticsTab.allCases) { tab in
                Button { viewModel.tab = tab } label: {
                    Text(tab.label)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(tab == viewModel.tab
                                    ? AnalyticsTheme.accent.opacity(0.85)
                                    : Color.white.opacity(0.07))
                        )
                        .foregroundStyle(tab == viewModel.tab ? .black : .white.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.tab {
        case .signal: signalTab
        case .hops: hopsTab
        case .peers: peersTab
        case .activity: activityTab
        case .packetTypes: packetTypesTab
        }
    }

    // MARK: Tabs

    private var signalTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            distributionPanel("SNR distribution", unit: "dB", dist: viewModel.snr)
            distributionPanel("RSSI distribution", unit: "dBm", dist: viewModel.rssi)
        }
    }

    private func distributionPanel(_ title: String, unit: String, dist: SignalDistribution) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                if let mean = dist.mean {
                    Text("mean \(oneDP(mean)) \(unit) · n=\(dist.sampleCount)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HistogramChart(bars: dist.bins.map { (oneDP($0.midpoint), Double($0.count)) })
                .frame(height: 130)
        }
    }

    private var hopsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hop-count distribution").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            Text("Hops travelled (hop_start − hop_limit) per reception.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HistogramChart(
                bars: viewModel.hops.map { ("\($0.hops)", Double($0.count)) },
                barColor: Color(red: 0.6, green: 0.7, blue: 1.0)
            )
            .frame(maxHeight: .infinity)
        }
    }

    private var peersTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Heard by").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            Text("Gateways/relays that heard this node — edge weight ∝ receptions, hue ∝ avg SNR.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            PeerTopologyGraph(
                nodeName: viewModel.nodeName ?? Self.hex(viewModel.nodeNum),
                peers: viewModel.peers
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var activityTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity by hour (UTC)").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            Text("Receptions per hour-of-day.").font(.system(size: 11)).foregroundStyle(.secondary)
            HourlyHeatmap(buckets: viewModel.hourly)
                .frame(height: 90)
            Spacer(minLength: 0)
        }
    }

    private var packetTypesTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Packet types").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            Text("Decoded packets grouped by MeshPort.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            PacketTypeBreakdown(counts: viewModel.packetTypes)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Chrome

    private func card(@ViewBuilder _ inner: () -> some View) -> some View {
        inner()
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(AnalyticsTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func oneDP(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func hex(_ nodeNum: Int64) -> String {
        NodeID.hex(UInt32(truncatingIfNeeded: nodeNum))
    }
}

#Preview("Node analytics") {
    NodeAnalyticsPreview()
        .frame(width: 900, height: 620)
}

/// Wrapper so the `#Preview` can build the seeded view model without a throwing
/// expression at the macro site.
private struct NodeAnalyticsPreview: View {
    @State private var viewModel: NodeAnalyticsViewModel?

    var body: some View {
        Group {
            if let viewModel {
                NodeAnalyticsView(viewModel: viewModel)
            } else {
                Color.clear
            }
        }
        .task {
            viewModel = try? AnalyticsPreviewData.nodeAnalyticsViewModel()
        }
    }
}
