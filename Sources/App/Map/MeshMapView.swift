// MeshMapView — the real MapKit substrate for the headline map (SPEC §1.1, ADR
// 0007). An NSViewRepresentable wrapping MKMapView: dark configuration, fit-to-fleet
// region, annotation clustering, and one MKPointAnnotation per positioned NetworkNode
// at its real lat/lon. Position-less nodes are omitted upstream (NetworkNode always
// carries a position; the view model drops nodes without a fix — SPEC §2.3).
//
// This is the live-app substrate only: MKMapView needs tiles/GPU and won't render
// under the headless ImageRenderer snapshot gate, so it's excluded from coverage like
// the other I/O adapters and verified live. The animated traces draw in a separate
// transparent Canvas overlay (TraceOverlayCanvas) positioned by the MapProjection
// this view publishes on every region change.
//
// MapKit is a system framework — no Package.swift change.

#if canImport(MapKit) && os(macOS)
    import Domain
    import MapKit
    import SwiftUI

    /// Shared, main-actor state bridging the MKMapView substrate and the Canvas overlay.
    /// The substrate writes the current `MapProjection` here whenever the map's region
    /// changes (pan/zoom/fit); the overlay reads it to place traces. `region` bumps a
    /// revision so SwiftUI re-renders the overlay in lock-step with the map.
    @MainActor
    @Observable
    public final class MeshMapState {
        /// Monotonic counter bumped on every region change — drives overlay refresh.
        public private(set) var regionRevision: Int = 0
        /// Latest projection from the live map, or nil before the map has laid out.
        public private(set) var projection: MapProjection?

        public init() {}

        /// Called by the substrate's coordinator after the map region settles.
        func update(projection: MapProjection) {
            self.projection = projection
            regionRevision &+= 1
        }
    }

    public struct MeshMapView: NSViewRepresentable {
        public let nodes: [NetworkNode]
        public let state: MeshMapState
        /// Whether to auto-fit the camera to the fleet — but only ever ONCE, on the
        /// first-ever launch (Task 1). After that the saved region is restored and the
        /// camera stays put when nodes are added.
        public var fitToFleet: Bool
        /// Persists / restores the visible region across restarts (Task 1).
        public var regionStore: MapRegionStore
        /// Called with a tapped node's id when its marker is selected (Task 5).
        public var onSelectNode: ((Int64) -> Void)?

        public init(
            nodes: [NetworkNode],
            state: MeshMapState,
            fitToFleet: Bool = true,
            regionStore: MapRegionStore = MapRegionStore(),
            onSelectNode: ((Int64) -> Void)? = nil
        ) {
            self.nodes = nodes
            self.state = state
            self.fitToFleet = fitToFleet
            self.regionStore = regionStore
            self.onSelectNode = onSelectNode
        }

        public func makeCoordinator() -> Coordinator {
            Coordinator(state: state, regionStore: regionStore, onSelectNode: onSelectNode)
        }

        public func updateNSView(_ map: MKMapView, context: Context) {
            // Keep the selection callback fresh across SwiftUI updates (it closes over
            // @State setters that change identity per render).
            context.coordinator.onSelectNode = onSelectNode
            sync(map: map, context: context)
        }

        public func makeNSView(context: Context) -> MKMapView {
            let map = MKMapView()
            map.delegate = context.coordinator
            applyDarkConfiguration(to: map)
            map.showsCompass = false
            map.showsZoomControls = true
            map.isPitchEnabled = false
            // Cluster dense annotations.
            map.register(
                MeshNodeAnnotationView.self,
                forAnnotationViewWithReuseIdentifier: MeshNodeAnnotationView.reuseID
            )
            map.register(
                MKMarkerAnnotationView.self,
                forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier
            )
            context.coordinator.attach(map: map)
            restoreInitialRegion(map: map, context: context)
            sync(map: map, context: context)
            return map
        }

        // MARK: Initial region (once)

        /// Set the starting camera exactly once, at view creation:
        ///  - If a region was saved on a previous run, restore it (camera stays where
        ///    the user left it).
        ///  - Otherwise (first-ever launch) start at the SF Bay Area and arm a one-shot
        ///    auto-fit so the camera frames the fleet as soon as nodes arrive.
        /// Either way the map never re-zooms when nodes are later added (Task 1).
        private func restoreInitialRegion(map: MKMapView, context: Context) {
            if let saved = regionStore.load() {
                map.setRegion(saved.asCoordinateRegion, animated: false)
                context.coordinator.armOneShotFit(false)
            } else {
                map.setRegion(
                    PersistedMapRegion.sanFranciscoBayArea.asCoordinateRegion,
                    animated: false
                )
                context.coordinator.armOneShotFit(fitToFleet)
            }
        }

        // MARK: Sync

        private func sync(map: MKMapView, context: Context) {
            let desired = nodes.map(MeshNodeAnnotation.init(node:))
            let existing = map.annotations.compactMap { $0 as? MeshNodeAnnotation }

            let desiredIDs = Set(desired.map(\.nodeID))
            let existingIDs = Set(existing.map(\.nodeID))

            let toRemove = existing.filter { !desiredIDs.contains($0.nodeID) }
            let toAdd = desired.filter { !existingIDs.contains($0.nodeID) }
            if !toRemove.isEmpty { map.removeAnnotations(toRemove) }
            // Update coordinates of survivors in place (a node may have moved).
            for annotation in existing where desiredIDs.contains(annotation.nodeID) {
                if let match = desired.first(where: { $0.nodeID == annotation.nodeID }) {
                    annotation.apply(match)
                }
            }
            if !toAdd.isEmpty { map.addAnnotations(toAdd) }

            // Auto-fit happens at most ONCE ever (first-ever launch, when nodes first
            // appear). It is NOT re-run when nodes are added later — that was the bug
            // that re-zoomed the map on every ingest (Task 1). The coordinator clears
            // the one-shot flag after firing.
            if !desired.isEmpty, context.coordinator.consumeOneShotFitIfArmed() {
                fit(map: map, to: desired)
            }
            // Publish the projection on the NEXT main-actor turn — NEVER synchronously
            // here. Mutating the observed `MeshMapState` inside `updateNSView` re-enters
            // the SwiftUI update and spins the view graph (a startup beachball). The
            // `fit()` above also triggers the region-change delegate, which publishes.
            let coordinator = context.coordinator
            Task { @MainActor in coordinator.publishProjection() }
        }

        private func fit(map: MKMapView, to annotations: [MeshNodeAnnotation]) {
            guard !annotations.isEmpty else { return }
            if annotations.count == 1, let only = annotations.first {
                let region = MKCoordinateRegion(
                    center: only.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
                )
                map.setRegion(region, animated: false)
                return
            }
            var rect = MKMapRect.null
            for annotation in annotations {
                let point = MKMapPoint(annotation.coordinate)
                rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
            }
            let padding = NSEdgeInsets(top: 80, left: 80, bottom: 80, right: 80)
            map.setVisibleMapRect(rect, edgePadding: padding, animated: false)
        }

        private func applyDarkConfiguration(to map: MKMapView) {
            let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            config.pointOfInterestFilter = .excludingAll
            map.preferredConfiguration = config
            map.appearance = NSAppearance(named: .darkAqua)
        }

        // MARK: Coordinator

        @MainActor
        public final class Coordinator: NSObject, MKMapViewDelegate {
            private let state: MeshMapState
            private let regionStore: MapRegionStore
            /// Called with a tapped node's id (Task 5). Refreshed on each SwiftUI update.
            var onSelectNode: ((Int64) -> Void)?
            private weak var map: MKMapView?
            /// Armed for a single auto-fit (first-ever launch only); cleared once fired.
            private var oneShotFitArmed = false
            /// Debounces persisting the region so a pan/zoom gesture saves once it
            /// settles, not on every intermediate frame.
            private var saveWorkItem: DispatchWorkItem?
            /// Wall-clock time of the last spiderfy pass — throttles the per-frame
            /// continuous-motion path (item 5).
            var lastSpiderfyAt: TimeInterval = 0
            /// The leader-line endpoints (anchor+displaced screen points keyed by id) from
            /// the last pass; lets us skip the overlay remove/add when nothing moved.
            var lastLeaderSignature: [Int64: SpiderLeaderKey] = [:]
            /// Min seconds between continuous-motion spiderfy passes.
            static let spiderfyInterval: TimeInterval = 0.1

            init(state: MeshMapState, regionStore: MapRegionStore, onSelectNode: ((Int64) -> Void)?) {
                self.state = state
                self.regionStore = regionStore
                self.onSelectNode = onSelectNode
            }

            func attach(map: MKMapView) {
                self.map = map
            }

            /// Arm (or disarm) the one-shot fleet fit. Called once from the initial
            /// region setup: armed only on the first-ever launch.
            func armOneShotFit(_ armed: Bool) {
                oneShotFitArmed = armed
            }

            /// Returns true (and disarms) exactly once if a one-shot fit is pending.
            func consumeOneShotFitIfArmed() -> Bool {
                guard oneShotFitArmed else { return false }
                oneShotFitArmed = false
                return true
            }

            /// Persist the current visible region, debounced. Runs off the observed
            /// state (UserDefaults), so it never re-enters the SwiftUI update loop.
            private func scheduleRegionSave() {
                saveWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, let map else { return }
                    regionStore.save(PersistedMapRegion(region: map.region))
                }
                saveWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
            }

            /// Build a MapProjection from the live map and hand it to the shared state.
            func publishProjection() {
                guard let map else { return }
                // The map view is the overlay's coordinate space; convert lat/lon → its
                // own bounds. Capturing `map` weakly avoids a retain cycle; if it's gone
                // we project to the origin (the overlay will simply have nothing to draw).
                let projection = MapProjection { [weak map] geo in
                    guard let map else { return .zero }
                    let coordinate = CLLocationCoordinate2D(latitude: geo.latitude, longitude: geo.longitude)
                    return map.convert(coordinate, toPointTo: map)
                }
                state.update(projection: projection)
            }

            public func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
                publishProjection()
                // The gesture/animation has settled — do the full, authoritative spiderfy
                // pass (fan markers + rebuild leader lines) exactly once here.
                applySpiderfy(on: mapView, settled: true)
                scheduleRegionSave()
            }

            public func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
                publishProjection()
                // Fires every frame during a continuous pan/zoom. Item 5: keep the cheap
                // projection publish so the Canvas overlay tracks the map, but THROTTLE
                // the expensive spiderfy (O(n²) cluster + overlay remove/add) so it runs
                // at most once per `spiderfyInterval`, not 60×/sec. The settled callback
                // above guarantees a final correct pass when motion stops.
                throttledSpiderfy(on: mapView)
            }

            public func mapView(
                _ mapView: MKMapView,
                rendererFor overlay: any MKOverlay
            ) -> MKOverlayRenderer {
                guard let line = overlay as? MKPolyline else {
                    return MKOverlayRenderer(overlay: overlay)
                }
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = NSColor.white.withAlphaComponent(0.45)
                renderer.lineWidth = 1
                return renderer
            }

            public func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
                guard let annotation = view.annotation as? MeshNodeAnnotation else { return }
                onSelectNode?(annotation.nodeID)
                // Deselect immediately so the same marker can be tapped again to reopen
                // the popover (MapKit otherwise suppresses re-selection of the current).
                mapView.deselectAnnotation(annotation, animated: false)
            }

            public func mapView(
                _ mapView: MKMapView,
                viewFor annotation: any MKAnnotation
            ) -> MKAnnotationView? {
                if annotation is MKClusterAnnotation {
                    let view = mapView.dequeueReusableAnnotationView(
                        withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier,
                        for: annotation
                    )
                    if let marker = view as? MKMarkerAnnotationView {
                        marker.markerTintColor = .systemTeal
                        marker.titleVisibility = .hidden
                    }
                    return view
                }
                guard let node = annotation as? MeshNodeAnnotation else { return nil }
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: MeshNodeAnnotationView.reuseID,
                    for: node
                )
                (view as? MeshNodeAnnotationView)?.configure(for: node)
                return view
            }
        }
    }

    // MARK: PersistedMapRegion ↔ MapKit bridge

    extension PersistedMapRegion {
        /// Build from a live MKMapView region (delegate side).
        init(region: MKCoordinateRegion) {
            self.init(
                centerLatitude: region.center.latitude,
                centerLongitude: region.center.longitude,
                latitudeSpan: region.span.latitudeDelta,
                longitudeSpan: region.span.longitudeDelta
            )
        }

        /// The MapKit region to restore.
        var asCoordinateRegion: MKCoordinateRegion {
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude),
                span: MKCoordinateSpan(latitudeDelta: latitudeSpan, longitudeDelta: longitudeSpan)
            )
        }
    }
#endif
