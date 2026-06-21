// MapProjection — the coordinate-source adapter that lets the trace-drawing code be
// shared between the live MapKit map and the headless Canvas (ADR 0007). It exposes
// the SAME `point(for: GeoPoint) -> CGPoint` shape as `GeoProjection`, but is backed
// by `MKMapView.convert(_:toPointTo:)` rather than an equirectangular rect.
//
// We don't want the overlay's drawing code to depend on MapKit, so MapProjection
// stores the conversion as a closure (`convert`) captured from the live map view on
// the main actor. The Canvas overlay calls `point(for:)` exactly as it would call
// `GeoProjection.point(for:)`; only the supplier differs.

import CoreGraphics
import Domain

/// A projection that places geographic points into the overlay's view space.
/// `GeoProjection` is the rect-backed implementation; this is the MapKit-backed one.
/// Both answer `point(for:)`, so the trace renderer is projection-agnostic.
public struct MapProjection {
    /// Converts a geographic point to a point in the overlay coordinate space.
    private let convert: (GeoPoint) -> CGPoint

    /// Wrap an arbitrary lat/lon → view-point conversion (e.g. one closing over
    /// `MKMapView.convert(_:toPointTo:)`). The closure is captured on the main actor
    /// where MapKit requires it; this type just forwards.
    public init(convert: @escaping (GeoPoint) -> CGPoint) {
        self.convert = convert
    }

    /// Project a geographic point into overlay space — same contract as
    /// `GeoProjection.point(for:)`.
    public func point(for geo: GeoPoint) -> CGPoint {
        convert(geo)
    }
}

/// Adopted by both `GeoProjection` and `MapProjection` so the shared trace renderer
/// can accept either coordinate source.
public protocol TraceProjection {
    func point(for geo: GeoPoint) -> CGPoint
}

extension GeoProjection: TraceProjection {}
extension MapProjection: TraceProjection {}
