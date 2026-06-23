// NodePicker — a bespoke dark-theme node selector for the per-node sections
// (Telemetry / Analytics). NOT a stock `Picker`/`Menu`: those render badly under
// the headless ImageRenderer snapshot gate, so this is a hand-rolled chip row +
// search field in the same style as the directory's role tabs and the telemetry
// range picker.
//
// It is driven by `NodePickerViewModel` (load + ranking + filtering live there);
// this view is a dumb renderer that reports the operator's tap back up. The chips
// flag which nodes carry position data (a filled dot) so the operator can steer
// toward the ones with something to show.

import SwiftUI

/// A horizontal, searchable row of node chips. Calls `onSelect` when the operator
/// taps a different node; the parent owns the selection and content swap.
struct NodePicker: View {
    let entries: [NodePickerEntry]
    let selection: Int64?
    @Binding var searchText: String
    let onSelect: (Int64) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
            chipRow
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Filter nodes by name or !hexid", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white)
                .frame(maxWidth: 280, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var chipRow: some View {
        if entries.isEmpty {
            Text("No nodes match the filter")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.vertical, 6)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(entries) { entry in
                        chip(entry)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func chip(_ entry: NodePickerEntry) -> some View {
        let active = entry.nodeNum == selection
        return Button { onSelect(entry.nodeNum) } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(entry.hasPositionData ? AnalyticsTheme.accent : Color.white.opacity(0.25))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(entry.hexID)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(active ? .black.opacity(0.6) : .white.opacity(0.45))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(active ? AnalyticsTheme.accent.opacity(0.9) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(active ? Color.clear : .white.opacity(0.08), lineWidth: 1)
            )
            .foregroundStyle(active ? .black : .white.opacity(0.85))
        }
        .buttonStyle(.plain)
    }
}

#Preview("Node picker") {
    NodePickerPreview()
        .frame(width: 720, height: 120)
        .background(AnalyticsTheme.background)
}

/// Stateful preview wrapper so the chip-tap + search round-trip is exercisable.
private struct NodePickerPreview: View {
    @State private var selection: Int64? = 0xA1B2_C3D4
    @State private var searchText = ""

    private let entries: [NodePickerEntry] = [
        NodePickerEntry(
            nodeNum: 0xA1B2_C3D4, name: "Oakland", hexID: "!a1b2c3d4",
            lastActivity: 5000, hasPositionData: true
        ),
        NodePickerEntry(
            nodeNum: 0x1111_2222, name: "Berkeley Relay", hexID: "!11112222",
            lastActivity: 4000, hasPositionData: true
        ),
        NodePickerEntry(
            nodeNum: 0x3333_4444, name: "Passer-by", hexID: "!33334444",
            lastActivity: 1000, hasPositionData: false
        )
    ]

    var body: some View {
        NodePicker(
            entries: entries,
            selection: selection,
            searchText: $searchText,
            onSelect: { selection = $0 }
        )
        .padding(24)
    }
}
