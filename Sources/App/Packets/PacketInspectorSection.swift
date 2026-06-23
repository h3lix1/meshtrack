// PacketInspectorSection — the bespoke master/detail packet inspector (G6). A
// recent-packets list (master, each id its own PacketColor) beside a detail pane
// that decodes one packet down to its fields, a byte-level hex dump, the
// receive→publish latency, and a small latency distribution over the window.
//
// Hand-rolled rows + a Canvas histogram (no stock List/ScrollView/TabView) so the
// section renders deterministically under the headless ImageRenderer snapshot gate
// (cf. memory: stock controls render badly headless). This is the entry point the
// lead wires into the AppShell's packet-inspector section.

import Domain
import SwiftUI

public struct PacketInspectorSection: View {
    @State private var viewModel: PacketInspectorViewModel

    public init(viewModel: PacketInspectorViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        HStack(spacing: 0) {
            recentList
                .frame(width: 300)
                .frame(maxHeight: .infinity)
                .background(PacketInspectorTheme.panel)
            Divider().overlay(.white.opacity(0.08))
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PacketInspectorTheme.background)
        .foregroundStyle(.white)
    }

    // MARK: List pane

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("RECENT PACKETS")
                    .font(.system(size: 10, weight: .bold)).tracking(1)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(viewModel.visiblePackets.count)")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }
            FilterBar(viewModel: viewModel)
            // The rows live in a vertical ScrollView anchored at the TOP (item 5): the
            // list is newest-first, so new arrivals appear at the top without shoving
            // the viewport, and selecting a row never scrolls. `rowStack` is a bespoke,
            // intrinsically-sized subview (no trailing Spacer, no stock List) — mirrors
            // CollisionMatrixView's `pageContent` so headless ImageRenderer snapshots
            // render the whole stack instead of a collapsed strip.
            ScrollView(.vertical) {
                rowStack
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(12)
    }

    /// The bespoke, intrinsically-sized row stack inside the master ScrollView.
    private var rowStack: some View {
        VStack(spacing: 4) {
            ForEach(viewModel.visiblePackets) { aggregate in
                PacketRow(
                    aggregate: aggregate,
                    isSelected: aggregate.packetID == viewModel.selected?.packetID
                )
                .contentShape(Rectangle())
                .onTapGesture { viewModel.selectedID = aggregate.packetID }
            }
            if viewModel.visiblePackets.isEmpty {
                Text(viewModel.packets.isEmpty ? "Awaiting traffic…" : "No packets match the filter.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 24)
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let aggregate = viewModel.selected {
            PacketDetailPane(aggregate: aggregate, distribution: viewModel.latencyDistribution)
        } else {
            VStack(spacing: 8) {
                Text("No packet selected")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Master row

private struct PacketRow: View {
    let aggregate: AggregatedPacket
    let isSelected: Bool

    private var color: Color {
        PacketColor.color(for: aggregate.packetID)
    }

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(color)
                .frame(width: 9, height: 9)
                .shadow(color: color, radius: 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(InspectedPacket.hexID(aggregate.packetID).replacingOccurrences(of: "!", with: "#"))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.white)
                    if aggregate.receptionCount > 1 {
                        Text("×\(aggregate.receptionCount)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(color)
                    }
                }
                Text(aggregate.portName)
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer()
            if let millis = aggregate.lastHeardLatencyMillis {
                Text("\(millis)ms")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            if let hopRange = aggregate.hopRangeText {
                Text("\(hopRange)h")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(
            isSelected ? Color.white.opacity(0.09) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}

enum PacketInspectorTheme {
    static let background = Color(red: 0.03, green: 0.04, blue: 0.10)
    static let panel = Color(red: 0.05, green: 0.06, blue: 0.14)
    static let accent = Color(hue: 0.55, saturation: 0.8, brightness: 1.0)
}

#Preview("Packet inspector — master/detail") {
    PacketInspectorSection(viewModel: PacketInspectorSample.viewModel())
        .frame(width: 920, height: 600)
}
