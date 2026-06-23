// MeshMapView+Declutter — MapKit delegate and zoom-density decluttering helpers.
// Split out from MeshMapView so the substrate wrapper stays within lint limits.

#if canImport(MapKit) && os(macOS)
    import AppKit
    import MapKit

    public extension MeshMapView.Coordinator {
        @discardableResult
        internal func refreshDeclutterLevel(on mapView: MKMapView) -> MapDeclutterLevel {
            let visibleNodeCount = mapView.annotations.compactMap { $0 as? MeshNodeAnnotation }.count
            let next = MapDeclutterPolicy.level(
                metersPerPoint: metersPerScreenPoint(on: mapView),
                visibleNodeCount: visibleNodeCount
            )
            guard next != declutterLevel else { return next }
            declutterLevel = next
            reconfigureAnnotationViews(on: mapView)
            return next
        }

        private func reconfigureAnnotationViews(on mapView: MKMapView) {
            for annotation in mapView.annotations {
                reconfigure(annotation, on: mapView)
            }
        }

        private func reconfigure(_ annotation: any MKAnnotation, on mapView: MKMapView) {
            if let node = annotation as? MeshNodeAnnotation {
                let view = mapView.view(for: node) as? MeshNodeAnnotationView
                view?.applyDeclutterAppearance(for: node, declutterLevel: declutterLevel)
            } else if let cluster = annotation as? MKClusterAnnotation {
                let marker = mapView.view(for: cluster) as? MKMarkerAnnotationView
                marker.map { Self.configureCluster($0, for: cluster) }
            }
        }

        private func metersPerScreenPoint(on mapView: MKMapView) -> Double {
            let width = Double(max(mapView.bounds.width, 1))
            let mapPointsPerScreenPoint = mapView.visibleMapRect.size.width / width
            return mapPointsPerScreenPoint
                * MKMetersPerMapPointAtLatitude(mapView.centerCoordinate.latitude)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            publishProjection(interacting: false, force: true)
            // The gesture/animation has settled. Run the authoritative spiderfy pass
            // once here, while continuous pan/zoom uses the throttled path below.
            applySpiderfy(on: mapView, settled: true)
            scheduleRegionSave()
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            publishProjection(interacting: true, force: false)
            throttledSpiderfy(on: mapView)
        }

        func mapView(
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

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let cluster = view.annotation as? MKClusterAnnotation {
                zoom(mapView, to: cluster)
                mapView.deselectAnnotation(cluster, animated: false)
                return
            }
            guard let annotation = view.annotation as? MeshNodeAnnotation else { return }
            onSelectNode?(annotation.nodeID)
            // Deselect immediately so the same marker can be tapped again to reopen
            // the popover; MapKit suppresses re-selection of the current annotation.
            mapView.deselectAnnotation(annotation, animated: false)
        }

        private func zoom(_ mapView: MKMapView, to cluster: MKClusterAnnotation) {
            var rect = MKMapRect.null
            for annotation in cluster.memberAnnotations {
                let point = MKMapPoint(annotation.coordinate)
                rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
            }
            guard !rect.isNull else { return }
            if rect.size.width == 0, rect.size.height == 0 {
                guard let first = cluster.memberAnnotations.first else { return }
                mapView.setRegion(
                    MKCoordinateRegion(
                        center: first.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                    ),
                    animated: true
                )
                return
            }
            mapView.setVisibleMapRect(
                rect,
                edgePadding: NSEdgeInsets(top: 80, left: 80, bottom: 80, right: 80),
                animated: true
            )
        }

        func mapView(
            _ mapView: MKMapView,
            viewFor annotation: any MKAnnotation
        ) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier,
                    for: annotation
                )
                if let marker = view as? MKMarkerAnnotationView {
                    Self.configureCluster(marker, for: cluster)
                }
                return view
            }
            guard let node = annotation as? MeshNodeAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: MeshNodeAnnotationView.reuseID,
                for: node
            )
            (view as? MeshNodeAnnotationView)?.configure(for: node, declutterLevel: declutterLevel)
            return view
        }

        private static func configureCluster(
            _ marker: MKMarkerAnnotationView,
            for cluster: MKClusterAnnotation
        ) {
            marker.markerTintColor = .systemTeal
            marker.glyphTintColor = .black
            marker.glyphText = "\(cluster.memberAnnotations.count)"
            marker.titleVisibility = .hidden
            marker.subtitleVisibility = .hidden
            marker.displayPriority = .required
            marker.canShowCallout = false
        }
    }
#endif
