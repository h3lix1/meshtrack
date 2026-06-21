// CollisionMatrixPreviewData — a deterministic node set with deliberate last-byte
// and short-id collisions, for previews / snapshots / tests.

import Foundation

public enum CollisionMatrixPreviewData {
    /// Nodes engineered so several share a last byte (and two share a short id),
    /// exercising the heatmap collisions and the short-id list.
    public static func nodes() -> [CollisionNode] {
        [
            // Three nodes whose ids end in 0xd4 → ambiguous relay byte.
            CollisionNode(nodeNum: 0xA1B2_C3D4, name: "BASE"),
            CollisionNode(nodeNum: 0x1122_33D4, name: "RELAY-A"),
            CollisionNode(nodeNum: 0x99AA_BBD4, name: "RELAY-B"),
            // Two nodes sharing short id c3d4 (also last byte d4) → short-id clash.
            CollisionNode(nodeNum: 0x5555_C3D4, name: "TWIN"),
            // Distinct last bytes.
            CollisionNode(nodeNum: 0x0000_0001, name: "GW-1"),
            CollisionNode(nodeNum: 0x0000_0002, name: "GW-2"),
            CollisionNode(nodeNum: 0xDEAD_BE7F, name: "MOBILE"),
            CollisionNode(nodeNum: 0xCAFE_F00D, name: "SENSOR"),
        ]
    }

    @MainActor public static func viewModel() -> CollisionMatrixViewModel {
        CollisionMatrixViewModel(nodes: nodes())
    }
}
