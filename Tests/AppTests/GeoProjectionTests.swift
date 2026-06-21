@testable import App
import CoreGraphics
import Domain
import Testing

@Suite("GeoProjection + packet colours")
struct GeoProjectionTests {
    private let rect = CGRect(x: 0, y: 0, width: 100, height: 100)

    @Test
    func `north maps up and east maps right`() {
        let projection = GeoProjection(
            points: [GeoPoint(latitude: 0, longitude: 0), GeoPoint(latitude: 10, longitude: 10)],
            in: rect, padding: 0
        )
        let north = projection.point(for: GeoPoint(latitude: 10, longitude: 5))
        let south = projection.point(for: GeoPoint(latitude: 0, longitude: 5))
        let east = projection.point(for: GeoPoint(latitude: 5, longitude: 10))
        let west = projection.point(for: GeoPoint(latitude: 5, longitude: 0))
        #expect(north.y < south.y)
        #expect(east.x > west.x)
    }

    @Test
    func `a single-point (degenerate) box does not divide by zero`() {
        let projection = GeoProjection(points: [GeoPoint(latitude: 37, longitude: -122)], in: rect)
        let point = projection.point(for: GeoPoint(latitude: 37, longitude: -122))
        #expect(point.x.isFinite)
        #expect(point.y.isFinite)
    }

    @Test
    func `packet colours are deterministic per id`() {
        #expect(PacketColor.color(for: 0x2A3B_4C5D) == PacketColor.color(for: 0x2A3B_4C5D))
        #expect(PacketColor.color(for: 1) != PacketColor.color(for: 2))
    }
}
