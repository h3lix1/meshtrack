// NodeDataSectionView — the node-aware wrapper for the per-node sections
// (Telemetry / Analytics). It is the drop-in replacement for the old
// `PerNodeSectionView`, whose only node-selection logic was "take
// `allNodes().first`" — i.e. the most-recently-heard node, which is frequently a
// transient passer-by with no retained data, so the section looked empty even
// when other nodes were rich with telemetry/positions.
//
// This composes a bespoke `NodePicker` (ranked, searchable) above the per-node
// content. The content closure mirrors `PerNodeSectionView`'s `(Int64) -> Content`
// shape, so the lead swaps the call site without touching the inner views; the
// content is re-keyed on the selected node so each view reloads cleanly on a swap.
//
// Bespoke chrome (no stock `Picker`/`List`) so the whole section renders faithfully
// under the headless ImageRenderer snapshot gate.

import Domain
import Persistence
import SwiftUI

public struct NodeDataSectionView<Content: View>: View {
    @State private var viewModel: NodePickerViewModel
    private let title: String
    @ViewBuilder private let content: (Int64) -> Content

    public init(
        store: MeshStore,
        title: String,
        @ViewBuilder content: @escaping (Int64) -> Content
    ) {
        _viewModel = State(initialValue: NodePickerViewModel(store: store))
        self.title = title
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if viewModel.loaded {
                picker
            }
            contentArea
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AnalyticsTheme.background)
        .task { try? await viewModel.load() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
            if viewModel.loaded, !viewModel.isEmpty {
                Text("\(viewModel.entries.count) nodes")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var picker: some View {
        NodePicker(
            entries: viewModel.filteredEntries,
            selection: viewModel.selection,
            searchText: Binding(
                get: { viewModel.searchText },
                set: { viewModel.searchText = $0 }
            ),
            onSelect: { viewModel.select($0) }
        )
    }

    @ViewBuilder
    private var contentArea: some View {
        if let nodeNum = viewModel.selection {
            // Re-key on the node so a selection swap tears down and rebuilds the
            // inner view (and its `.task`-driven reload) instead of mutating state.
            content(nodeNum).id(nodeNum)
        } else if viewModel.isEmpty {
            message("No nodes yet", "Nothing has been heard on the mesh.")
        } else {
            message("Loading…", "Reading the node directory.")
        }
    }

    private func message(_ headline: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Text(headline).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Node data section") {
    NodeDataSectionPreview()
        .frame(width: 820, height: 600)
}

/// Wrapper that seeds an in-memory store, then drives the section so the picker +
/// content swap is exercisable (mirrors the telemetry/analytics previews).
private struct NodeDataSectionPreview: View {
    @State private var store: MeshStore?
    private let now: Int64 = 1000 * 3_600_000_000_000

    var body: some View {
        Group {
            if let store {
                NodeDataSectionView(store: store, title: "Telemetry") { nodeNum in
                    TelemetryChartsView(viewModel: TelemetryChartsViewModel(
                        store: store,
                        nodeNum: nodeNum,
                        now: { Instant(nanosecondsSinceEpoch: now) }
                    ))
                }
            } else {
                Color.clear
            }
        }
        .task {
            guard let seeded = try? await AnalyticsPreviewData.seededStore(nowNanos: now) else { return }
            try? await seeded.upsertNode(NodeRecord(
                node_num: AnalyticsPreviewData.nodeNum,
                short_name: AnalyticsPreviewData.nodeName,
                first_seen_at: 0,
                last_heard_at: now
            ))
            store = seeded
        }
    }
}
