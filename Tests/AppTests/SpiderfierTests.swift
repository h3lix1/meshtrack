@testable import App
import CoreGraphics
import Testing

@Suite("Spiderfier — co-located annotation fan-out")
struct SpiderfierTests {
    @Test
    func `a lone point is left exactly where it is`() {
        let placements = Spiderfier.spiderfy(points: [(id: 1, point: CGPoint(x: 100, y: 100))])
        #expect(placements.count == 1)
        let only = placements[0]
        #expect(only.isFanned == false)
        #expect(only.displaced == only.anchor)
        #expect(only.displaced == CGPoint(x: 100, y: 100))
    }

    @Test
    func `well-separated points are never fanned`() {
        let points = [
            (id: Int64(1), point: CGPoint(x: 0, y: 0)),
            (id: Int64(2), point: CGPoint(x: 500, y: 500))
        ]
        let placements = Spiderfier.spiderfy(points: points)
        let anyFanned = placements.contains { $0.isFanned }
        #expect(anyFanned == false)
    }

    @Test
    func `co-located points are fanned onto the radius around their centroid`() {
        // Three nodes at (almost) the same pixel — the classic stacked-mast site.
        let points = [
            (id: Int64(3), point: CGPoint(x: 200, y: 200)),
            (id: Int64(1), point: CGPoint(x: 201, y: 200)),
            (id: Int64(2), point: CGPoint(x: 200, y: 201))
        ]
        let placements = Spiderfier.spiderfy(points: points, radius: 30)
        #expect(placements.count == 3)
        let allFanned = placements.contains { !$0.isFanned } == false
        #expect(allFanned)

        // All share the centroid anchor…
        let anchors = Set(placements.map { "\($0.anchor.x),\($0.anchor.y)" })
        #expect(anchors.count == 1)

        // …and each displaced point sits ~radius from the anchor.
        for placement in placements {
            let deltaX = placement.displaced.x - placement.anchor.x
            let deltaY = placement.displaced.y - placement.anchor.y
            let radius = (deltaX * deltaX + deltaY * deltaY).squareRoot()
            #expect(abs(radius - 30) < 1e-6)
        }
    }

    @Test
    func `fan order is stable (sorted by id), independent of input order`() {
        let unsorted = [
            (id: Int64(9), point: CGPoint(x: 50, y: 50)),
            (id: Int64(2), point: CGPoint(x: 50, y: 50)),
            (id: Int64(5), point: CGPoint(x: 50, y: 50))
        ]
        let forward = Spiderfier.spiderfy(points: unsorted)
        let reverse = Spiderfier.spiderfy(points: unsorted.reversed())
        // The displaced position for a given id must be identical regardless of input
        // ordering — the angular slot is keyed on the sorted id, not arrival.
        for id in [Int64(2), 5, 9] {
            let fromForward = forward.first { $0.id == id }
            let fromReverse = reverse.first { $0.id == id }
            #expect(fromForward?.displaced == fromReverse?.displaced)
        }
    }

    @Test
    func `clustering is transitive via single-link proximity`() {
        // A—B within proximity, B—C within proximity, A—C not — still one chain.
        let points = [
            (id: Int64(1), point: CGPoint(x: 0, y: 0)),
            (id: Int64(2), point: CGPoint(x: 10, y: 0)),
            (id: Int64(3), point: CGPoint(x: 20, y: 0))
        ]
        let groups = Spiderfier.cluster(points: points, proximity: 12)
        #expect(groups.count == 1)
        #expect(groups[0].count == 3)
    }
}
