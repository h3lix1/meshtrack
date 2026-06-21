// SearchRanker — the pure ranking behind the ⌘K palette (G10). Given a query and
// the corpus, it scores each item by how well its keywords match, and returns the
// best results first. No SwiftUI, no I/O — fully unit-tested.

import Foundation

public enum SearchRanker {
    /// Score weights, highest-signal first. An exact keyword match beats a prefix,
    /// which beats a substring; multiple matching keywords add up.
    enum Weight {
        static let exact = 100
        static let prefix = 50
        static let substring = 20
        /// Bonus when the item title itself starts with the query (most relevant).
        static let titlePrefix = 30
    }

    /// Rank `corpus` against `query`, best-first. A blank query returns nothing
    /// (the palette shows its empty state). `limit` caps the result count.
    public static func rank(query rawQuery: String, in corpus: [SearchItem], limit: Int = 20) -> [SearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }

        let results = corpus.compactMap { item -> SearchResult? in
            let score = self.score(item, query: query)
            return score > 0 ? SearchResult(item: item, score: score) : nil
        }
        return Array(results.sorted().prefix(limit))
    }

    /// The match score of one item against an already-normalised `query`. Zero
    /// means no match (filtered out).
    static func score(_ item: SearchItem, query: String) -> Int {
        var total = 0
        for keyword in item.keywords {
            if keyword == query {
                total += Weight.exact
            } else if keyword.hasPrefix(query) {
                total += Weight.prefix
            } else if keyword.contains(query) {
                total += Weight.substring
            }
        }
        if item.title.lowercased().hasPrefix(query) {
            total += Weight.titlePrefix
        }
        return total
    }
}
