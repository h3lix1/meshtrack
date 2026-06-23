// SearchPreviewData — a deterministic corpus for previews / snapshots / tests.

import Foundation

public enum SearchPreviewData {
    /// A small mixed corpus (nodes, packets, a channel).
    public static func corpus() -> [SearchItem] {
        [
            SearchViewModel.nodeItem(nodeNum: 0xA1B2_C3D4, shortName: "BASE", longName: "Base Station"),
            SearchViewModel.nodeItem(nodeNum: 0x1122_3344, shortName: "RELAY", longName: "Ridge Relay"),
            SearchViewModel.nodeItem(nodeNum: 0xDEAD_BEEF, shortName: "ROAM", longName: "Roamer"),
            SearchViewModel.packetItem(packetID: 4242, fromNum: 0xA1B2_C3D4),
            SearchViewModel.packetItem(packetID: 1001, fromNum: 0x1122_3344),
            SearchViewModel.channelItem(channel: 0, name: "LongFast"),
            SearchViewModel.channelItem(channel: 1, name: "Ops")
        ]
    }

    @MainActor public static func viewModel(query: String = "") -> SearchViewModel {
        let viewModel = SearchViewModel(corpus: corpus())
        viewModel.query = query
        return viewModel
    }
}
