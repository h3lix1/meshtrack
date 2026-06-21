// MeshNodeAnnotation / MeshNodeAnnotationView — the MapKit annotation that puts each
// positioned NetworkNode on the real map (SPEC §1.1). The annotation carries the node
// id + display fields and enables clustering; the view draws a small node marker
// (gateway-tinted) under the Canvas trace overlay. Live-app substrate only (excluded
// from the headless snapshot/coverage gate, ADR 0007).

#if canImport(MapKit) && os(macOS)
    import AppKit
    import Domain
    import MapKit

    /// One node pinned at its real lat/lon. `clusteringIdentifier` enables MapKit's
    /// built-in clustering for dense areas (SPEC §1.1).
    final class MeshNodeAnnotation: NSObject, MKAnnotation {
        let nodeID: Int64
        @objc dynamic var coordinate: CLLocationCoordinate2D
        var title: String?
        private(set) var isGateway: Bool
        private(set) var batteryPercent: Double?
        private(set) var hopsFromGateway: Int

        init(node: NetworkNode) {
            nodeID = node.id
            coordinate = CLLocationCoordinate2D(
                latitude: node.position.latitude,
                longitude: node.position.longitude
            )
            title = node.name
            isGateway = node.isGateway
            batteryPercent = node.batteryPercent
            hopsFromGateway = node.hopsFromGateway
            super.init()
        }

        /// Update mutable fields in place when a node moves or its stats change, so the
        /// annotation (and any open callout) tracks the latest data without a remove/add.
        func apply(_ other: MeshNodeAnnotation) {
            coordinate = other.coordinate
            title = other.title
            isGateway = other.isGateway
            batteryPercent = other.batteryPercent
            hopsFromGateway = other.hopsFromGateway
        }
    }

    /// A compact circular marker for a node; gateways read teal, members blue-violet by
    /// hop distance. The animated traces and glows are drawn by the Canvas overlay above,
    /// so this view stays intentionally minimal.
    final class MeshNodeAnnotationView: MKAnnotationView {
        static let reuseID = "MeshNodeAnnotationView"

        override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
            super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
            collisionMode = .circle
            canShowCallout = true
            frame = CGRect(x: 0, y: 0, width: 16, height: 16)
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        func configure(for annotation: MeshNodeAnnotation) {
            self.annotation = annotation
            clusteringIdentifier = "mesh-node"
            displayPriority = annotation.isGateway ? .required : .defaultHigh
            toolTip = annotation.title
            guard let layer else { return }
            let color = Self.color(for: annotation)
            layer.cornerRadius = 8
            layer.backgroundColor = color.withAlphaComponent(0.95).cgColor
            layer.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
            layer.borderWidth = annotation.isGateway ? 2 : 1
        }

        private static func color(for annotation: MeshNodeAnnotation) -> NSColor {
            if annotation.isGateway { return NSColor(red: 0.3, green: 0.95, blue: 1.0, alpha: 1) }
            switch annotation.hopsFromGateway {
            case 0, 1: return NSColor(red: 0.45, green: 0.85, blue: 1.0, alpha: 1)
            case 2: return NSColor(red: 0.6, green: 0.7, blue: 1.0, alpha: 1)
            default: return NSColor(red: 0.75, green: 0.6, blue: 1.0, alpha: 1)
            }
        }
    }
#endif
