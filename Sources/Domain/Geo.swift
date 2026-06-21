// Geo primitives for movement detection (SPEC §2.3).
//
// Domain stays free of Foundation; the trig comes from the platform math library
// (`Darwin`), used here only for pure, deterministic math (no I/O). Distances are
// Haversine great-circle metres.

import Darwin

public struct GeoPoint: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum Haversine {
    private static let earthRadiusMeters = 6_371_000.0

    /// Great-circle distance in metres between two points. Symmetric; 0 for equal
    /// points; bounded by half the Earth's circumference.
    public static func distanceMeters(from start: GeoPoint, to end: GeoPoint) -> Double {
        let phi1 = start.latitude * .pi / 180
        let phi2 = end.latitude * .pi / 180
        let deltaPhi = (end.latitude - start.latitude) * .pi / 180
        let deltaLambda = (end.longitude - start.longitude) * .pi / 180

        let sinHalfPhi = sin(deltaPhi / 2)
        let sinHalfLambda = sin(deltaLambda / 2)
        let haversine = sinHalfPhi * sinHalfPhi + cos(phi1) * cos(phi2) * sinHalfLambda * sinHalfLambda
        return 2 * earthRadiusMeters * asin(min(1, haversine.squareRoot()))
    }
}
