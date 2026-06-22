// CollisionMatrixPreviewData — a deterministic node set with deliberate last-byte
// and short-id collisions (plus seeded positions) for previews / snapshots / tests.
// Positions are chosen so the 0xd4 collision bucket shows all three earshot verdicts:
// two nodes close together (in range), one far away (out of range), and one with no
// fix at all (unknown).

import Domain
import Foundation

public enum CollisionMatrixPreviewData {
    /// Nodes engineered so several share a last byte (and two share a short id),
    /// exercising the heatmap collisions and the short-id list.
    public static func nodes() -> [CollisionNode] {
        [
            // Four nodes whose ids end in 0xd4 → ambiguous relay byte.
            CollisionNode(nodeNum: 0xA1B2_C3D4, name: "BASE"),
            CollisionNode(nodeNum: 0x1122_33D4, name: "RELAY-A"),
            CollisionNode(nodeNum: 0x99AA_BBD4, name: "RELAY-B"),
            // Two nodes sharing short id c3d4 (also last byte d4) → short-id clash.
            CollisionNode(nodeNum: 0x5555_C3D4, name: "TWIN"),
            // Distinct last bytes.
            CollisionNode(nodeNum: 0x0000_0001, name: "GW-1"),
            CollisionNode(nodeNum: 0x0000_0002, name: "GW-2"),
            CollisionNode(nodeNum: 0xDEAD_BE7F, name: "MOBILE"),
            CollisionNode(nodeNum: 0xCAFE_F00D, name: "SENSOR")
        ]
    }

    /// Last-known fixes for the colliding nodes, keyed by `nodeNum`. BASE and RELAY-A
    /// sit ~1.4 km apart in central London (in range); RELAY-B is in Edinburgh (~530
    /// km, out of range); TWIN has no fix (unknown). The rest are uninteresting for
    /// earshot and left out.
    public static func positions() -> [Int64: GeoPoint] {
        [
            0xA1B2_C3D4: GeoPoint(latitude: 51.5074, longitude: -0.1278), // BASE — London
            0x1122_33D4: GeoPoint(latitude: 51.5194, longitude: -0.1270), // RELAY-A — ~1.3 km N
            0x99AA_BBD4: GeoPoint(latitude: 55.9533, longitude: -3.1883) // RELAY-B — Edinburgh
            // TWIN (0x5555_C3D4) intentionally absent → earshot "unknown".
        ]
    }

    @MainActor public static func viewModel() -> CollisionMatrixViewModel {
        CollisionMatrixViewModel(nodes: nodes(), positions: positions())
    }

    /// A view model pre-selected on the 0xd4 collision so previews/snapshots exercise
    /// the click-through detail panel and earshot rows without a tap.
    @MainActor public static func selectedViewModel() -> CollisionMatrixViewModel {
        let viewModel = viewModel()
        viewModel.select(byte: 0xD4)
        return viewModel
    }
}
