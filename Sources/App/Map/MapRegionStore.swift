// MapRegionStore — persists the map's visible region (center + span) across app
// restarts (Task 1). The live MKMapView delegate writes here (debounced) on every
// settled region change, and the view restores from here on first layout. We persist
// to UserDefaults — NOT the Domain/Persistence store — deliberately: the camera is a
// pure UI preference, not mesh data, and must never re-enter the SwiftUI update loop
// (writing it from the delegate, off the observed state, keeps the view graph quiet —
// ADR 0007's "don't mutate observed state in updateNSView" rule).
//
// The "first ever launch" flag is what makes auto-fit happen exactly once: the very
// first time the app runs there is no saved region, so we default the camera to the
// SF Bay Area and let the fleet-fit run; every launch after that restores the saved
// region and auto-fit is suppressed.

import Foundation

/// A serialisable map region (center lat/lon + span deltas). Mirrors
/// `MKCoordinateRegion` without importing MapKit, so it is unit-testable headless.
public struct PersistedMapRegion: Equatable, Sendable {
    public var centerLatitude: Double
    public var centerLongitude: Double
    public var latitudeSpan: Double
    public var longitudeSpan: Double

    public init(
        centerLatitude: Double,
        centerLongitude: Double,
        latitudeSpan: Double,
        longitudeSpan: Double
    ) {
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.latitudeSpan = latitudeSpan
        self.longitudeSpan = longitudeSpan
    }

    /// The first-ever default: the SF Bay Area, ~0.5° span (Task 1).
    public static let sanFranciscoBayArea = PersistedMapRegion(
        centerLatitude: 37.77,
        centerLongitude: -122.42,
        latitudeSpan: 0.5,
        longitudeSpan: 0.5
    )

    /// Whether every field is finite and the spans are positive — a guard against
    /// restoring a corrupt/degenerate region that MapKit would reject.
    public var isValid: Bool {
        let finite = centerLatitude.isFinite && centerLongitude.isFinite
            && latitudeSpan.isFinite && longitudeSpan.isFinite
        let inRange = abs(centerLatitude) <= 90 && abs(centerLongitude) <= 180
        let positiveSpan = latitudeSpan > 0 && longitudeSpan > 0
        return finite && inRange && positiveSpan
    }
}

/// UserDefaults-backed persistence of the map's visible region. Stored as four
/// doubles under stable keys. `load()` returns nil on the first-ever launch (no key
/// written yet), which is the signal the view uses to auto-fit exactly once.
public struct MapRegionStore: Sendable {
    /// UserDefaults is documented thread-safe but not marked Sendable; the store holds
    /// only a reference to it and is read/written from the main actor (the map delegate).
    private nonisolated(unsafe) let defaults: UserDefaults

    private enum Key {
        static let centerLat = "meshtrack.map.region.centerLat"
        static let centerLon = "meshtrack.map.region.centerLon"
        static let spanLat = "meshtrack.map.region.spanLat"
        static let spanLon = "meshtrack.map.region.spanLon"
        static let hasLaunched = "meshtrack.map.region.hasLaunched"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the app has ever persisted a region. False only on the first-ever
    /// launch; once true the view restores instead of auto-fitting.
    public var hasEverLaunched: Bool {
        defaults.bool(forKey: Key.hasLaunched)
    }

    /// The persisted region, or nil if none has been stored (first launch) or the
    /// stored value is degenerate.
    public func load() -> PersistedMapRegion? {
        guard hasEverLaunched else { return nil }
        let region = PersistedMapRegion(
            centerLatitude: defaults.double(forKey: Key.centerLat),
            centerLongitude: defaults.double(forKey: Key.centerLon),
            latitudeSpan: defaults.double(forKey: Key.spanLat),
            longitudeSpan: defaults.double(forKey: Key.spanLon)
        )
        return region.isValid ? region : nil
    }

    /// Persist the region. Marks the app as launched so future loads restore it.
    /// No-op for a degenerate region (we never want to save a corrupt camera).
    public func save(_ region: PersistedMapRegion) {
        guard region.isValid else { return }
        defaults.set(region.centerLatitude, forKey: Key.centerLat)
        defaults.set(region.centerLongitude, forKey: Key.centerLon)
        defaults.set(region.latitudeSpan, forKey: Key.spanLat)
        defaults.set(region.longitudeSpan, forKey: Key.spanLon)
        defaults.set(true, forKey: Key.hasLaunched)
    }
}
