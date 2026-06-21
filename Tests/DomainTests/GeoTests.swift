@testable import Domain
import Testing

@Suite("Haversine geo math")
struct GeoTests {
    @Test
    func `distance is zero for the same point`() {
        let point = GeoPoint(latitude: 37.77, longitude: -122.41)
        #expect(Haversine.distanceMeters(from: point, to: point) == 0)
    }

    @Test
    func `distance is symmetric`() {
        let a = GeoPoint(latitude: 37.0, longitude: -122.0)
        let b = GeoPoint(latitude: 37.1, longitude: -122.2)
        let ab = Haversine.distanceMeters(from: a, to: b)
        let ba = Haversine.distanceMeters(from: b, to: a)
        #expect(abs(ab - ba) < 1e-6)
    }

    @Test
    func `one degree of latitude is about 111 km`() {
        let distance = Haversine.distanceMeters(
            from: GeoPoint(latitude: 0, longitude: 0),
            to: GeoPoint(latitude: 1, longitude: 0)
        )
        #expect(abs(distance - 111_195) < 500)
    }

    @Test
    func `a small northward offset matches the metre count`() {
        let a = GeoPoint(latitude: 37.0, longitude: -122.0)
        let b = GeoPoint(latitude: 37.0 + 150 / 111_320, longitude: -122.0)
        #expect(abs(Haversine.distanceMeters(from: a, to: b) - 150) < 1)
    }
}
