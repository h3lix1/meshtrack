@testable import App
import Testing

@Suite("Search ranking")
struct SearchRankerTests {
    private func item(_ title: String, _ keywords: [String], target: SearchTarget = .node(nodeNum: 1)) -> SearchItem {
        SearchItem(
            id: title, kind: .node, title: title, subtitle: "",
            keywords: keywords, target: target
        )
    }

    @Test
    func `blank query returns nothing`() {
        let corpus = [item("BASE", ["base"])]
        #expect(SearchRanker.rank(query: "", in: corpus).isEmpty)
        #expect(SearchRanker.rank(query: "   ", in: corpus).isEmpty)
    }

    @Test
    func `exact match outranks prefix outranks substring`() {
        let exact = item("Exact", ["base"])
        let prefix = item("Prefix", ["baseball"])
        let substring = item("Substring", ["database"])
        let results = SearchRanker.rank(query: "base", in: [substring, prefix, exact])
        #expect(results.map(\.item.title) == ["Exact", "Prefix", "Substring"])
        #expect(results[0].score > results[1].score)
        #expect(results[1].score > results[2].score)
    }

    @Test
    func `non-matching items are filtered out`() {
        let corpus = [item("BASE", ["base"]), item("ROAM", ["roam"])]
        let results = SearchRanker.rank(query: "base", in: corpus)
        #expect(results.count == 1)
        #expect(results[0].item.title == "BASE")
    }

    @Test
    func `search is case-insensitive`() {
        let corpus = [item("BASE", ["Base Station"])]
        #expect(SearchRanker.rank(query: "BASE", in: corpus).count == 1)
        #expect(SearchRanker.rank(query: "station", in: corpus).count == 1)
    }

    @Test
    func `multiple matching keywords accumulate score`() {
        let many = item("Many", ["base", "based", "baseline"]) // 3 prefix hits
        let one = item("One", ["base"]) // 1 exact hit
        let results = SearchRanker.rank(query: "base", in: [one, many])
        // 3×prefix (150) beats 1×exact (100); titlePrefix doesn't apply to either.
        #expect(results.first?.item.title == "Many")
    }

    @Test
    func `title-prefix bonus breaks otherwise-equal matches`() {
        // Both have one substring keyword hit; only "Baseline" title starts with the query.
        let titled = item("Baseline", ["xbase"])
        let plain = item("Other", ["xbase"])
        let results = SearchRanker.rank(query: "base", in: [plain, titled])
        #expect(results.first?.item.title == "Baseline")
    }

    @Test
    func `limit caps the number of results`() {
        let corpus = (0..<30).map { item("n\($0)", ["base\($0)"]) }
        #expect(SearchRanker.rank(query: "base", in: corpus, limit: 5).count == 5)
    }

    @Test
    func `packet ids match in decimal and hex`() {
        let corpus = [SearchViewModel.packetItem(packetID: 0x10A2, fromNum: 1)]
        #expect(SearchRanker.rank(query: "4258", in: corpus).count == 1) // decimal
        #expect(SearchRanker.rank(query: "10a2", in: corpus).count == 1) // hex
    }
}
