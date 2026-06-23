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
    /// Bound for the whole floating panel; the packet/receiver roster scrolls inside it.
    private let maxHeight: CGFloat

    public init(
        settings: VizSettings,
        traces: [PacketTrace],
        relayCandidateCount: Int = 1,
        selectedPacketID: UInt32? = nil,
        maxHeight: CGFloat = 520,
        onSelectPacket: ((UInt32) -> Void)? = nil
    ) {
        _settings = Bindable(settings)
        self.traces = traces
        self.relayCandidateCount = relayCandidateCount
        self.selectedPacketID = selectedPacketID
        self.maxHeight = maxHeight
        self.onSelectPacket = onSelectPacket
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            timingControls
            Divider().overlay(Color.white.opacity(0.12))
            edgeKey
            Divider().overlay(Color.white.opacity(0.12))
            scrollableRoster
        }
        .padding(14)
        .frame(width: PanelLayout.width, alignment: .topLeading)
        .frame(maxHeight: maxHeight, alignment: .topLeading)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12), lineWidth: 1))
        .foregroundStyle(.white)
    }

    /// The focused packet's complete "received by (reported)" roster (item 8): every
    /// receiver we have evidence for — both the nodes ringed on the map and the ones we can
    /// only list because we have no position to draw them — each with its reception hop.
    /// Only shown when a packet is focused and the toggle is on. The "(reported)" qualifier
    /// is deliberate: this is what the mesh reports, not every silent overhearer.
    @ViewBuilder
    private var receivedBySection: some View {
        let rows = focusedReceiverRows
        if !rows.isEmpty {
            Divider().overlay(Color.white.opacity(0.12))
            ReceivedByList(rows: rows)
        }
    }

    /// The focused packet's receiver roster, or empty when nothing is focused / the toggle
    /// is off — kept off the view body so the `if` above stays single-condition.
    private var focusedReceiverRows: [VizLegend.ReceiverRow] {
        guard settings.showAllReceivers,
              let focused = selectedPacketID,
              let trace = traces.first(where: { $0.id == focused })
        else { return [] }
        return VizLegend.receivedBy(trace)
    }

    private var scrollableRoster: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                legend
                receivedBySection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: rosterMaxHeight, alignment: .top)
        .scrollIndicators(.visible)
    }

    private var rosterMaxHeight: CGFloat {
        max(PanelLayout.minRosterHeight, maxHeight - PanelLayout.fixedChromeHeight)
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
            VStack(alignment: .leading, spacing: 4) {
                Text("Relay guesses").font(.caption)
                Picker("Relay guesses", selection: $settings.relayGuessingPolicy) {
                    Text("Nearest").tag(RelayGuessingPolicy.nearestCandidate)
                    Text("Unique").tag(RelayGuessingPolicy.unambiguousOnly)
                    Text("All").tag(RelayGuessingPolicy.allCandidates)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(settings.relayGuessingDetail)
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.55))
            }
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

private enum PanelLayout {
    static let width: CGFloat = 240
    static let fixedChromeHeight: CGFloat = 190
    static let minRosterHeight: CGFloat = 96
}

/// The focused packet's "received by (reported)" roster (item 8). Lists every receiver we
/// have evidence for: the ones ringed on the map (`onMap`) and the ones we could only list
/// because we have no position to draw them (a dot beside the row distinguishes the two).
/// The "(reported)" heading is honest — this is what the mesh reports (gateways, guessed
/// relays, the addressed destination), NOT every node that silently overheard the packet.
private struct ReceivedByList: View {
    let rows: [VizLegend.ReceiverRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Received by (reported)")
                .font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.7))
            ForEach(rows) { row in
                receiverRow(row)
            }
            Text("only nodes the mesh reported \u{2014} silent overhearers are unknowable")
                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
        }
    }

    private func receiverRow(_ row: VizLegend.ReceiverRow) -> some View {
        HStack(spacing: 8) {
            // Filled dot = drawn on the map; hollow dot = listed-only (no known position).
            Circle()
                .strokeBorder(.white.opacity(0.7), lineWidth: 1)
                .background(Circle().fill(row.onMap ? .white.opacity(0.7) : .clear))
                .frame(width: 7, height: 7)
            Text(row.label).font(.system(size: 10).monospaced())
            Text(row.roleLabel).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
            Spacer()
            Text("hop \(row.hop)").font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
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
