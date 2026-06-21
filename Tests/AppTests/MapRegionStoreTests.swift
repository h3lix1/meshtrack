@testable import App
import Foundation
import Testing

@Suite("MapRegionStore + PersistedMapRegion (camera persistence)")
struct MapRegionStoreTests {
    /// A fresh, isolated UserDefaults suite per test so we never touch the real domain.
    private func freshDefaults() -> UserDefaults {
        let suite = "meshtrack.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("could not create test defaults")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test
    func `first-ever launch has no saved region`() {
        let store = MapRegionStore(defaults: freshDefaults())
        #expect(store.hasEverLaunched == false)
        #expect(store.load() == nil)
    }

    @Test
    func `saving then loading round-trips the region and marks launched`() {
        let store = MapRegionStore(defaults: freshDefaults())
        let region = PersistedMapRegion(
            centerLatitude: 37.42, centerLongitude: -122.08,
            latitudeSpan: 0.3, longitudeSpan: 0.4
        )
        store.save(region)
        #expect(store.hasEverLaunched)
        #expect(store.load() == region)
    }

    @Test
    func `a degenerate region is never saved`() {
        let store = MapRegionStore(defaults: freshDefaults())
        // Zero span → invalid; must not flip the launched flag.
        store.save(PersistedMapRegion(
            centerLatitude: 0, centerLongitude: 0, latitudeSpan: 0, longitudeSpan: 0
        ))
        #expect(store.hasEverLaunched == false)
        #expect(store.load() == nil)
    }

    @Test
    func `out-of-range center is rejected as invalid`() {
        let bad = PersistedMapRegion(
            centerLatitude: 200, centerLongitude: 999, latitudeSpan: 1, longitudeSpan: 1
        )
        #expect(bad.isValid == false)
    }

    @Test
    func `the first-ever default frames the SF Bay Area at half-degree span`() {
        let region = PersistedMapRegion.sanFranciscoBayArea
        #expect(region.isValid)
        #expect(abs(region.centerLatitude - 37.77) < 0.01)
        #expect(abs(region.centerLongitude - -122.42) < 0.01)
        #expect(abs(region.latitudeSpan - 0.5) < 1e-9)
    }
}
