// GeoProjection — maps node lat/lon into a canvas rect (equirectangular, good for
// a regional mesh). Pure + testable; the network map and overlays use it to place
// nodes and draw packet paths.

import CoreGraphics
import Domain

public struct GeoProjection: Sendable, Equatable {
    public let minLat: Double
    public let maxLat: Double
    public let minLon: Double
    public let maxLon: Double
    public let rect: CGRect

    /// Build a projection that fits `points` into `rect` with fractional `padding`.
    public init(points: [GeoPoint], in rect: CGRect, padding: Double = 0.12) {
        self.rect = rect
        let lats = points.map(\.latitude)
        let lons = points.map(\.longitude)
        var loLat = lats.min() ?? 0
        var hiLat = lats.max() ?? 0
        var loLon = lons.min() ?? 0
        var hiLon = lons.max() ?? 0
        // Avoid a degenerate (zero-span) box.
        if hiLat - loLat < 1e-6 { loLat -= 0.01; hiLat += 0.01 }
        if hiLon - loLon < 1e-6 { loLon -= 0.01; hiLon += 0.01 }
        let padLat = (hiLat - loLat) * padding
        let padLon = (hiLon - loLon) * padding
        minLat = loLat - padLat
        maxLat = hiLat + padLat
        minLon = loLon - padLon
        maxLon = hiLon + padLon
    }

    /// Project a geographic point to a canvas point (north = up).
    public func point(for geo: GeoPoint) -> CGPoint {
        let fractionX = (geo.longitude - minLon) / (maxLon - minLon)
        let fractionY = 1 - (geo.latitude - minLat) / (maxLat - minLat)
        return CGPoint(x: rect.minX + fractionX * rect.width, y: rect.minY + fractionY * rect.height)
    }
}
