@testable import App
import CoreGraphics
import Domain
import Testing

@Suite("Network map performance budgets")
struct MapPerformanceBudgetTests {
    @Test
    func `burst fixture has the dense workload shape used for profiling`() {
        let fixture = MapPerfFixture.make(.burst)

        #expect(fixture.nodes.count == 1000)
        #expect(fixture.traces.count == 96)
        #expect(fixture.latencyMillis.count == fixture.traces.count)
        #expect(Set(fixture.traces.map(\.id)).count == fixture.traces.count)
        #expect(fixture.nodes.contains { $0.isGateway })
        #expect(fixture.nodes.contains { $0.preset == .mediumFast })
        #expect(fixture.nodes.contains { $0.preset == .longFast })
    }

    @Test
    func `burst fixture stays clustered at mid zoom to avoid annotation noise`() {
        let fixture = MapPerfFixture.make(.burst)
        let level = MapDeclutterPolicy.level(metersPerPoint: 30, visibleNodeCount: fixture.nodes.count)

        #expect(level == .clustered)
        #expect(level.clustersAnnotations)
        #expect(!level.allowsSpiderfy)
    }

    @Test
    func `projection cache converts each unique coordinate once per frame`() {
        let base = CountingProjection()
        let cache = CachedTraceProjection(base: base)
        let first = GeoPoint(latitude: 37.7749, longitude: -122.4194)
        let second = GeoPoint(latitude: 37.8044, longitude: -122.2712)

        for _ in 0 ..< 20 {
            #expect(cache.point(for: first) == CGPoint(x: first.longitude, y: first.latitude))
        }
        for _ in 0 ..< 5 {
            #expect(cache.point(for: second) == CGPoint(x: second.longitude, y: second.latitude))
        }

        #expect(base.calls == 2)
    }
}

private final class CountingProjection: TraceProjection {
    private(set) var calls = 0

    func point(for geo: GeoPoint) -> CGPoint {
        calls += 1
        return CGPoint(x: geo.longitude, y: geo.latitude)
    }
}
