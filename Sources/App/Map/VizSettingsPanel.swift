// VizSettingsPanel — the floating controls over the map (SPEC §1.6, §1.3, §1.4):
//  - a hopDuration slider,
//  - an "equalise finish" toggle (every edge of a journey finishes together),
//  - a per-packet-id colour legend,
//  - a guessed-vs-observed key with a relay-confidence hint.
//
// It binds to the shared VizSettings model and reads the legend rows from the pure
// VizLegend helper. This is a live-app control surface; the deterministic snapshot
// path renders the self-contained Canvas map (DashboardView, live:false) per ADR 0007.

import Domain
import SwiftUI

public struct VizSettingsPanel: View {
    @Bindable private var settings: VizSettings
    private let traces: [PacketTrace]
    /// Worst-case relay-byte candidate count across the shown traces, for the hint.
    private let relayCandidateCount: Int
    /// The packet id currently isolated on the map (nil = all packets shown). Drives the
    /// legend-row highlight.
    private let selectedPacketID: UInt32?
    /// Tapping a legend row hands its packet id back to focus/toggle it; nil disables
    /// the interaction (e.g. preview/snapshot composition).
    private let onSelectPacket: ((UInt32) -> Void)?

    public init(
        settings: VizSettings,
        traces: [PacketTrace],
        relayCandidateCount: Int = 1,
        selectedPacketID: UInt32? = nil,
        onSelectPacket: ((UInt32) -> Void)? = nil
    ) {
        _settings = Bindable(settings)
        self.traces = traces
        self.relayCandidateCount = relayCandidateCount
        self.selectedPacketID = selectedPacketID
        self.onSelectPacket = onSelectPacket
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            timingControls
            Divider().overlay(Color.white.opacity(0.12))
            edgeKey
            Divider().overlay(Color.white.opacity(0.12))
            legend
        }
        .padding(14)
        .frame(width: 240, alignment: .leading)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12), lineWidth: 1))
        .foregroundStyle(.white)
    }

    // MARK: Timing

    private var timingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Animation").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.7))
            HStack {
                Text("Hop speed").font(.caption)
                Spacer()
                Text(String(format: "%.1fs", settings.hopDuration))
                    .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
            }
            Slider(
                value: $settings.hopDuration,
                in: VizSettings.minHopDuration ... VizSettings.maxHopDuration
            )
            Toggle(isOn: $settings.equaliseFinish) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Equalise finish").font(.caption)
                    Text("hops of a journey land together")
                        .font(.system(size: 9)).foregroundStyle(.white.opacity(0.55))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Toggle(isOn: $settings.showAllReceivers) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Show all receivers").font(.caption)
                    Text("ring every node that heard the focused packet")
                        .font(.system(size: 9)).foregroundStyle(.white.opacity(0.55))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    // MARK: Guessed / observed key

    private var edgeKey: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hops").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.7))
            keyRow(dashed: false, label: "observed", detail: "received by a gateway")
            keyRow(dashed: true, label: "\u{2248} guessed", detail: VizLegend.confidenceHint(
                candidateCount: relayCandidateCount
            ))
        }
    }

    private func keyRow(dashed: Bool, label: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            EdgeSwatch(dashed: dashed)
                .frame(width: 26, height: 10)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption)
                Text(detail).font(.system(size: 9)).foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    // MARK: Per-id colour legend

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Packets").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.7))
                Spacer()
                if let focused = selectedPacketID, let onSelectPacket {
                    Button("Show all") { onSelectPacket(focused) }
                        .buttonStyle(.plain)
                        .font(.system(size: 9).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .help("Show all packets")
                }
            }
            let entries = VizLegend.entries(for: traces)
            if entries.isEmpty {
                Text("no live traces").font(.caption).foregroundStyle(.white.opacity(0.5))
            } else {
                ForEach(entries) { entry in
                    legendRow(entry)
                }
            }
        }
    }

    @ViewBuilder
    private func legendRow(_ entry: VizLegend.Entry) -> some View {
        let isFocused = PacketFocus.isFocused(entry.id, selectedPacketID: selectedPacketID)
        let row = HStack(spacing: 8) {
            Circle().fill(entry.color).frame(width: 10, height: 10)
            Text(entry.label).font(.caption.monospaced())
            Spacer()
            Text("\(entry.hops)h").font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            if entry.guessedEdges > 0 {
                Text("\u{2248}").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(isFocused ? 0.18 : 0))
        )
        .contentShape(Rectangle())
        .opacity(selectedPacketID == nil || isFocused ? 1 : 0.5)

        if let onSelectPacket {
            Button { onSelectPacket(entry.id) } label: { row }
                .buttonStyle(.plain)
                .help(isFocused ? "Show all packets" : "Isolate this packet")
        } else {
            row
        }
    }
}

/// A tiny line swatch — dashed for guessed edges, solid for observed.
private struct EdgeSwatch: View {
    let dashed: Bool

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(
                path,
                with: .color(.white.opacity(0.85)),
                style: StrokeStyle(
                    lineWidth: dashed ? 1.6 : 2.8,
                    lineCap: .round,
                    dash: dashed ? [4, 3] : []
                )
            )
        }
    }
}
