@testable import App
import Domain
import Testing

#if canImport(MapKit) && os(macOS)
    import MapKit

    @Suite("MeshNodeAnnotationView clustering")
    @MainActor
    struct MeshNodeAnnotationViewTests {
        @Test
        func `declutter refresh does not mutate MapKit cluster identity or display priority`() {
            let annotation = MeshNodeAnnotation(node: NetworkNode(
                id: 1,
                name: "node",
                position: GeoPoint(latitude: 37.0, longitude: -122.0),
                hopsFromGateway: 1,
                isGateway: false
            ))
            let view = MeshNodeAnnotationView(
                annotation: annotation,
                reuseIdentifier: MeshNodeAnnotationView.reuseID
            )

            view.configure(for: annotation, declutterLevel: .overview)
            let clusterID = view.clusteringIdentifier
            let priority = view.displayPriority

            view.applyDeclutterAppearance(for: annotation, declutterLevel: .individual)

            #expect(view.clusteringIdentifier == clusterID)
            #expect(view.displayPriority == priority)
            #expect(view.alphaValue == 1)
        }
    }
#endif
