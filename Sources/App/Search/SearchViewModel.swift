// SearchViewModel — the ⌘K command-palette state (G10). Builds an in-memory
// corpus from the store (nodes / recent packets via observations / channels via
// messages), ranks results live as the query changes, and emits a `SearchTarget`
// the lead's router consumes. The corpus building and selection are pure; the
// ranking is `SearchRanker` (tested separately).

import Domain
import Observation
import Persistence
import SwiftUI

@Observable
@MainActor
public final class SearchViewModel {
    /// Whether the palette is presented. Bound to the ⌘K shortcut.
    public var isPresented = false
    /// The live query.
    public var query = "" {
        didSet { recomputeResults() }
    }

    /// Ranked results for the current query.
    public private(set) var results: [SearchResult] = []
    /// The last target the user selected (the lead observes this to route).
    public private(set) var selectedTarget: SearchTarget?

    @ObservationIgnored private var corpus: [SearchItem] = []
    @ObservationIgnored private let store: MeshStore?

    /// Store-backed: `reloadCorpus()` reads nodes/packets/channels from the store.
    public init(store: MeshStore) {
        self.store = store
    }

    /// Memory-only: seed the corpus directly (previews / tests / live coordinator).
    public init(corpus: [SearchItem] = []) {
        store = nil
        self.corpus = corpus
    }

    /// Rebuild the searchable corpus from the store. Call when the palette opens so
    /// results reflect the current fleet. A no-op for a memory-only VM.
    public func reloadCorpus(recentPacketLimit: Int = 200) async throws {
        guard let store else { return }
        var items: [SearchItem] = []

        for node in try await store.allNodes() {
            items.append(Self.nodeItem(node))
        }
        // Channels surfaced from recent messages (channel index + human name).
        var seenChannels: Set<Int64> = []
        for message in try await store.recentMessages(limit: recentPacketLimit) {
            if seenChannels.insert(message.channel).inserted {
                items.append(Self.channelItem(channel: message.channel, name: message.channel_name))
            }
            // The packet that carried the message is searchable by id.
            items.append(Self.packetItem(
                packetID: UInt32(truncatingIfNeeded: message.packet_id),
                fromNum: message.from_num
            ))
        }
        corpus = items
        recomputeResults()
    }

    /// Replace the corpus in-memory (live coordinator / tests).
    public func setCorpus(_ items: [SearchItem]) {
        corpus = items
        recomputeResults()
    }

    /// Select a result — records the target the router consumes and dismisses.
    public func select(_ result: SearchResult) {
        selectedTarget = result.item.target
        isPresented = false
    }

    /// Clear the recorded target once the router has consumed it.
    public func consumeTarget() {
        selectedTarget = nil
    }

    /// Open the palette (reset to a clean query).
    public func open() {
        query = ""
        results = []
        isPresented = true
    }

    private func recomputeResults() {
        results = SearchRanker.rank(query: query, in: corpus)
    }

    // MARK: Corpus item builders

    nonisolated static func nodeItem(_ record: NodeRecord) -> SearchItem {
        nodeItem(nodeNum: record.node_num, shortName: record.short_name, longName: record.long_name)
    }

    /// Record-free node-item builder (also used by previews/tests without a store).
    nonisolated static func nodeItem(nodeNum: Int64, shortName: String?, longName: String?) -> SearchItem {
        let hex = NodeID.hex(UInt32(truncatingIfNeeded: nodeNum))
        let short = NodeID.shortHex(UInt32(truncatingIfNeeded: nodeNum))
        let name = shortName ?? longName ?? hex
        var keywords = [name, hex, short, String(nodeNum)]
        if let longName { keywords.append(longName) }
        return SearchItem(
            id: "node-\(nodeNum)",
            kind: .node,
            title: name,
            subtitle: hex,
            keywords: keywords,
            target: .node(nodeNum: nodeNum)
        )
    }

    nonisolated static func packetItem(packetID: UInt32, fromNum: Int64) -> SearchItem {
        let fromHex = NodeID.hex(UInt32(truncatingIfNeeded: fromNum))
        return SearchItem(
            id: "packet-\(packetID)",
            kind: .packet,
            title: "Packet #\(packetID)",
            subtitle: "from \(fromHex)",
            keywords: [String(packetID), String(format: "%x", packetID), "packet"],
            target: .packet(packetID: packetID)
        )
    }

    nonisolated static func channelItem(channel: Int64, name: String?) -> SearchItem {
        let label = name ?? "Channel \(channel)"
        return SearchItem(
            id: "channel-\(channel)",
            kind: .channel,
            title: label,
            subtitle: "channel \(channel)",
            keywords: [label, "channel", String(channel), name ?? ""].filter { !$0.isEmpty },
            target: .channel(channel: channel)
        )
    }
}
