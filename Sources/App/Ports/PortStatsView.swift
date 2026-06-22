// PortStatsView — the Port-numbers screen (item 11). A bespoke dark-theme view (no
// stock List/ScrollView/Picker) so it renders deterministically under the headless
// ImageRenderer snapshot gate. Shows, per port: name + one-line description, packet
// count, % of traffic, distinct sources, distinct gateways, max hops — sorted by
// traffic. Extras (busiest channels, hop distribution) ride along the right rail.

import Domain
import SwiftUI

/// The section wrapper the composition root registers: owns the live view model and
/// renders the screen. Mirrors `PacketInspectorSection`'s shape.
public struct PortStatsSection: View {
    @State private var viewModel: PortStatsViewModel

    public init(viewModel: PortStatsViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        PortStatsView(
            rows: viewModel.rows,
            channels: viewModel.channels,
            hops: viewModel.hops,
            totalReceptions: viewModel.totalReceptions,
            totalDistinctPackets: viewModel.totalDistinctPackets
        )
    }
}

/// The pure presentation view: hand it rows, it draws. Easy to preview/snapshot.
public struct PortStatsView: View {
    public let rows: [PortStatRow]
    public let channels: [ChannelTrafficRow]
    public let hops: [HopBucketRow]
    public let totalReceptions: Int
    public let totalDistinctPackets: Int

    public init(
        rows: [PortStatRow],
        channels: [ChannelTrafficRow] = [],
        hops: [HopBucketRow] = [],
        totalReceptions: Int,
        totalDistinctPackets: Int
    ) {
        self.rows = rows
        self.channels = channels
        self.hops = hops
        self.totalReceptions = totalReceptions
        self.totalDistinctPackets = totalDistinctPackets
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            mainColumn
            Divider().overlay(.white.opacity(0.08))
            sideRail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.03, green: 0.04, blue: 0.10))
        .foregroundStyle(.white)
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            columnHeadings
            if rows.isEmpty {
                emptyState
            } else {
                ForEach(rows) { PortStatRowView(row: $0) }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Port Numbers").font(.system(size: 22, weight: .bold))
            Text("Application ports in recent traffic — counts are RECEPTIONS "
                + "(duplicate floods included); distinct packets shown alongside.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                metric("RECEPTIONS", "\(totalReceptions)")
                metric("DISTINCT PACKETS", "\(totalDistinctPackets)")
                metric("PORTS IN USE", "\(rows.count)")
            }
            .padding(.top, 4)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 17, weight: .bold, design: .rounded))
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
        }
    }

    private var columnHeadings: some View {
        HStack(spacing: 8) {
            Text("PORT").frame(width: 220, alignment: .leading)
            Text("PKTS").frame(width: 56, alignment: .trailing)
            Text("SHARE").frame(width: 72, alignment: .trailing)
            Text("SRC").frame(width: 44, alignment: .trailing)
            Text("GW").frame(width: 40, alignment: .trailing)
            Text("MAX HOP").frame(width: 64, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
        .padding(.bottom, 2)
    }

    private var emptyState: some View {
        Text("No traffic yet — ports appear as packets arrive.")
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.vertical, 24)
    }

    private var sideRail: some View {
        VStack(alignment: .leading, spacing: 18) {
            ChannelTrafficPanel(channels: channels)
            HopDistributionPanel(hops: hops)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.04, green: 0.05, blue: 0.12))
    }
}

/// One port row: catalogue name + description on the left, stats on the right, with a
/// share bar underlining the whole row.
struct PortStatRowView: View {
    let row: PortStatRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.descriptor.name)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        Text("\(row.descriptor.rawValue)")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.white.opacity(0.08), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Text(row.descriptor.summary).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 220, alignment: .leading)
                Text("\(row.receptions)").frame(width: 56, alignment: .trailing)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(row.sharePercentLabel).frame(width: 72, alignment: .trailing)
                    .font(.system(size: 12, weight: .medium))
                Text("\(row.sourceNodeCount)").frame(width: 44, alignment: .trailing)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                Text("\(row.gatewayCount)").frame(width: 40, alignment: .trailing)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                Text("\(row.maxHops)").frame(width: 64, alignment: .trailing)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(PortPalette.accent)
                Spacer(minLength: 0)
            }
            shareBar
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.05)).frame(height: 1)
        }
    }

    private var shareBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.05))
                Capsule().fill(PortPalette.accent.opacity(0.55))
                    .frame(width: max(3, geo.size.width * row.trafficShare))
            }
        }
        .frame(height: 3)
    }
}

enum PortPalette {
    static let accent = Color(red: 0.36, green: 0.78, blue: 0.98)
}
