// MeshMapSpiderfy — the co-located-marker fan-out for MeshMapView's coordinator,
// split out so MeshMapView stays within the lint length cap. It also carries the
// item-5 pan/zoom optimisation: the full spiderfy pass (an O(n²) cluster plus a
// MapKit overlay remove/add) is throttled during continuous motion and skipped
// entirely when the leader-line geometry hasn't changed, so dragging the map no
// longer churns overlays 60×/second.

#if canImport(MapKit) && os(macOS)
    import AppKit
    import Domain
    import MapKit

    /// A leader line's endpoints (rounded to whole pixels) — the cache key that lets a
    /// continuous pan skip rebuilding identical overlays.
    struct SpiderLeaderKey: Equatable {
        let anchor: CGPoint
        let displaced: CGPoint

        init(anchor: CGPoint, displaced: CGPoint) {
            self.anchor = CGPoint(x: anchor.x.rounded(), y: anchor.y.rounded())
            self.displaced = CGPoint(x: displaced.x.rounded(), y: displaced.y.rounded())
        }
    }

    extension MeshMapView.Coordinator {
        /// Identifier for the thin leader-line overlays drawn from a fanned marker back
        /// to its true (shared) coordinate.
        static var leaderTitle: String {
            "spiderfy-leader"
        }

        /// Run a spiderfy pass at most once per `spiderfyInterval` during continuous
        /// motion (item 5). The settled `regionDidChangeAnimated` callback always runs an
        /// authoritative final pass, so throttling here never leaves markers mis-fanned.
        func throttledSpiderfy(on mapView: MKMapView) {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastSpiderfyAt >= Self.spiderfyInterval else { return }
            applySpiderfy(on: mapView, settled: false)
        }

        /// Fan out co-located markers and refresh their leader lines. At a given zoom,
        /// only markers that still project within a few pixels of each other are fanned,
        /// so zooming in lets real neighbours separate on their own.
        ///
        /// `settled` is true on the final post-gesture pass: leader lines are only
        /// rebuilt then, or when their geometry actually changed, so a continuous drag
        /// just nudges the (cheap) marker offsets without overlay churn.
        func applySpiderfy(on mapView: MKMapView, settled: Bool) {
            MapPerfSignpost.interval("map.spiderfy") {
                applySpiderfyBody(on: mapView, settled: settled)
            }
        }

        private func applySpiderfyBody(on mapView: MKMapView, settled: Bool) {
            lastSpiderfyAt = ProcessInfo.processInfo.systemUptime
            let annotations = mapView.annotations.compactMap { $0 as? MeshNodeAnnotation }
            guard !annotations.isEmpty else {
                if !lastLeaderSignature.isEmpty { clearLeaderLines(on: mapView) }
                return
            }
            let points = annotations.map {
                (id: $0.nodeID, point: mapView.convert($0.coordinate, toPointTo: mapView))
            }
            let placements = Spiderfier.spiderfy(points: points)
            let byID = Dictionary(uniqueKeysWithValues: placements.map { ($0.id, $0) })

            // Offset each marker view to its fanned position (cheap; screen y is down,
            // matching MKAnnotationView.centerOffset on macOS).
            for annotation in annotations {
                guard let view = mapView.view(for: annotation),
                      let placement = byID[annotation.nodeID] else { continue }
                view.centerOffset = CGPoint(
                    x: placement.displaced.x - placement.anchor.x,
                    y: placement.displaced.y - placement.anchor.y
                )
            }

            refreshLeaderLines(on: mapView, placements: placements, force: settled)
        }

        /// Replace the leader-line overlays only when their geometry changed (or a
        /// settled pass forces it). The signature compares rounded endpoints, so an
        /// idle re-fire is a no-op and a continuous drag only rebuilds when lines move.
        private func refreshLeaderLines(
            on mapView: MKMapView, placements: [SpiderfiedPlacement], force: Bool
        ) {
            let fanned = placements.filter(\.isFanned)
            let signature = Dictionary(uniqueKeysWithValues: fanned.map {
                ($0.id, SpiderLeaderKey(anchor: $0.anchor, displaced: $0.displaced))
            })
            guard force || signature != lastLeaderSignature else { return }
            lastLeaderSignature = signature

            let stale = mapView.overlays.filter { ($0.title ?? nil) == Self.leaderTitle }
            if !stale.isEmpty { mapView.removeOverlays(stale) }
            let leaders = fanned.map { placement -> MKPolyline in
                let anchor = mapView.convert(placement.anchor, toCoordinateFrom: mapView)
                let displaced = mapView.convert(placement.displaced, toCoordinateFrom: mapView)
                let line = MKPolyline(coordinates: [anchor, displaced], count: 2)
                line.title = Self.leaderTitle
                return line
            }
            if !leaders.isEmpty { mapView.addOverlays(leaders) }
        }

        private func clearLeaderLines(on mapView: MKMapView) {
            let stale = mapView.overlays.filter { ($0.title ?? nil) == Self.leaderTitle }
            if !stale.isEmpty { mapView.removeOverlays(stale) }
            lastLeaderSignature = [:]
        }
    }
#endif
