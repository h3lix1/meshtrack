// SearchModels — the value types behind the global ⌘K command palette (G10): the
// searchable corpus (nodes / packets / channels), a ranked result, and the
// deep-link target a selection emits for the lead's router. Pure + `Sendable`, so
// the ranking is unit-tested with no SwiftUI.

import Foundation

/// Where a selected result routes. The lead's router maps this to a section +
/// in-section selection; it deliberately mirrors `AppSection`'s cases without
/// depending on the shell's routing so search stays self-contained.
public enum SearchTarget: Sendable, Equatable {
    /// Focus a node (Nodes / Network sections).
    case node(nodeNum: Int64)
    /// Open a packet in the inspector.
    case packet(packetID: UInt32)
    /// Open a channel in the Channels view.
    case channel(channel: Int64)
}

/// One searchable item in the in-memory corpus.
public struct SearchItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case node
        case packet
        case channel
    }

    /// Stable identity for SwiftUI lists (kind + primary key).
    public let id: String
    public let kind: Kind
    /// The primary display title (e.g. node short-name, "Packet #1234", channel name).
    public let title: String
    /// A secondary line (e.g. the hex id, the node a packet came from).
    public let subtitle: String
    /// Every string this item can match on, lower-cased at build time (name, hex id,
    /// short id, packet id in dec + hex, channel index/name).
    public let keywords: [String]
    /// What selecting this item routes to.
    public let target: SearchTarget

    public init(
        id: String,
        kind: Kind,
        title: String,
        subtitle: String,
        keywords: [String],
        target: SearchTarget
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords.map { $0.lowercased() }
        self.target = target
    }
}

/// A scored search result. `Comparable` so results sort best-first.
public struct SearchResult: Sendable, Equatable, Identifiable, Comparable {
    public let item: SearchItem
    /// Higher is better. See `SearchRanker` for the scoring rules.
    public let score: Int

    public var id: String { item.id }

    public init(item: SearchItem, score: Int) {
        self.item = item
        self.score = score
    }

    public static func < (lhs: SearchResult, rhs: SearchResult) -> Bool {
        // Sort by score desc, then title asc for a stable, deterministic order.
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.item.title.localizedCaseInsensitiveCompare(rhs.item.title) == .orderedAscending
    }
}
