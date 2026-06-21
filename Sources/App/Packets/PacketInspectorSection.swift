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
            ScrollViewReaderless {
                VStack(spacing: 4) {
                    ForEach(viewModel.visiblePackets) { packet in
                        PacketRow(packet: packet, isSelected: packet.id == viewModel.selected?.id)
                            .contentShape(Rectangle())
                            .onTapGesture { viewModel.selectedID = packet.id }
                    }
                    if viewModel.visiblePackets.isEmpty {
                        Text(viewModel.packets.isEmpty ? "Awaiting traffic…" : "No packets match the filter.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                    }
                }
            }
        }
        .padding(12)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let packet = viewModel.selected {
            PacketDetailPane(packet: packet, distribution: viewModel.latencyDistribution)
        } else {
            VStack(spacing: 8) {
                Text("No packet selected")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A non-clipping vertical container so the bespoke list renders fully under the
/// headless snapshot gate (stock ScrollView renders badly headless).
private struct ScrollViewReaderless<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content; Spacer(minLength: 0) }
    }
}

// MARK: - Master row

private struct PacketRow: View {
    let packet: InspectedPacket
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(PacketColor.color(for: packet.packetID))
                .frame(width: 9, height: 9)
                .shadow(color: PacketColor.color(for: packet.packetID), radius: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(InspectedPacket.hexID(packet.packetID).replacingOccurrences(of: "!", with: "#"))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.white)
                Text(packet.portName)
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer()
            if let millis = packet.latencyMillis {
                Text("\(millis)ms")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            if let hops = packet.hops {
                Text("\(hops)h")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PacketColor.color(for: packet.packetID))
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
