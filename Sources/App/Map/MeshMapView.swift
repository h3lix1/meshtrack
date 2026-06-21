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
        /// Whether to auto-fit the camera to the fleet when the node set changes.
        public var fitToFleet: Bool

        public init(nodes: [NetworkNode], state: MeshMapState, fitToFleet: Bool = true) {
            self.nodes = nodes
            self.state = state
            self.fitToFleet = fitToFleet
        }

        public func makeCoordinator() -> Coordinator {
            Coordinator(state: state)
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
            sync(map: map, context: context, initialFit: true)
            return map
        }

        public func updateNSView(_ map: MKMapView, context: Context) {
            sync(map: map, context: context, initialFit: false)
        }

        // MARK: Sync

        private func sync(map: MKMapView, context: Context, initialFit: Bool) {
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

            let changed = !toAdd.isEmpty || !toRemove.isEmpty
            if fitToFleet, !desired.isEmpty, initialFit || changed {
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
            private weak var map: MKMapView?

            init(state: MeshMapState) {
                self.state = state
            }

            func attach(map: MKMapView) {
                self.map = map
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
            }

            public func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
                publishProjection()
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
#endif
