// CollisionMatrixView — the bespoke 16×16 last-byte heatmap + short-id collision
// list (G10). Reveals which relay bytes are ambiguous (shared by several nodes),
// directly informing the map's relay-confidence hint. Pure-Canvas so it renders
// headless; backed by `CollisionMatrixViewModel` over the store.

import Domain
import Observation
import Persistence
import SwiftUI

/// Loads nodes from the store and exposes the collision analysis. `@MainActor
/// @Observable`; the analysis itself is the pure `CollisionMatrix` (tested
/// separately).
@Observable
@MainActor
public final class CollisionMatrixViewModel {
    public private(set) var analysis: CollisionAnalysis
    @ObservationIgnored private let store: MeshStore?

    /// Store-backed: `load()` reads the node set from the store.
    public init(store: MeshStore) {
        self.store = store
        analysis = CollisionMatrix.analyse([])
    }

    /// Memory-only: seeded from a node set (live coordinator / previews / tests).
    /// `load()` is a no-op; drive it with `update(nodes:)`.
    public init(nodes: [CollisionNode] = []) {
        store = nil
        analysis = CollisionMatrix.analyse(nodes)
    }

    /// Build the analysis from the store's current node set. A no-op when the VM
    /// is memory-only.
    public func load() async throws {
        guard let store else { return }
        let nodes = try await store.allNodes().map(Self.collisionNode)
        analysis = CollisionMatrix.analyse(nodes)
    }

    /// Re-run the analysis over an in-memory node set (live coordinator / tests).
    public func update(nodes: [CollisionNode]) {
        analysis = CollisionMatrix.analyse(nodes)
    }

    nonisolated static func collisionNode(_ record: NodeRecord) -> CollisionNode {
        let hex = "!" + String(format: "%08x", UInt32(truncatingIfNeeded: record.node_num))
        return CollisionNode(
            nodeNum: record.node_num,
            name: record.short_name ?? record.long_name ?? hex
        )
    }
}

/// The collision section: a header, the 16×16 last-byte heatmap, and the short-id
/// collision list.
public struct CollisionMatrixView: View {
    @State private var viewModel: CollisionMatrixViewModel

    public init(viewModel: CollisionMatrixViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            heatmapCard
            shortIDCard
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ObserveTheme.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Relay-byte collisions").font(.title.bold()).foregroundStyle(.white)
            Text("ids are 4 bytes but relay hints carry only the last — shared bytes "
                + "make the previous-hop guess ambiguous")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LAST-BYTE MATRIX (16×16)")
                    .font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                Text("worst: \(viewModel.analysis.maxLastByteCollision) nodes · "
                    + "\(viewModel.analysis.collidingByteCount) ambiguous bytes")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            CollisionHeatmap(buckets: viewModel.analysis.lastByteBuckets)
                .frame(height: 280)
        }
        .padding(16)
        .background(ObserveTheme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var shortIDCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SHORT-ID COLLISIONS")
                .font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            if viewModel.analysis.shortIDCollisions.isEmpty {
                Text("No short-id collisions")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.analysis.shortIDCollisions) { bucket in
                    CollisionRow(bucket: bucket)
                }
            }
        }
        .padding(16)
        .background(ObserveTheme.card, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// One short-id collision row: the short id + the colliding node names.
private struct CollisionRow: View {
    let bucket: CollisionBucket

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(bucket.key)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.orange)
                .frame(width: 44, alignment: .leading)
            Text(bucket.nodes.map(\.name).joined(separator: ", "))
                .font(.system(size: 12)).foregroundStyle(.white)
            Spacer()
            Text("×\(bucket.count)")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}

/// The 16×16 last-byte heatmap, drawn with `Canvas` so it renders deterministically
/// headless. Cell intensity tracks the number of nodes sharing that byte; a cell
/// with 2+ nodes (an ambiguous relay byte) is outlined.
struct CollisionHeatmap: View {
    let buckets: [CollisionBucket]

    var body: some View {
        Canvas { context, size in
            let cols = 16
            let rows = 16
            let gap: CGFloat = 2
            let cellW = (size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let cellH = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            let maxCount = max(buckets.map(\.count).max() ?? 0, 1)

            for bucket in buckets {
                guard let value = bucket.byteValue else { continue }
                let col = value % cols
                let row = value / cols
                let rect = CGRect(
                    x: CGFloat(col) * (cellW + gap),
                    y: CGFloat(row) * (cellH + gap),
                    width: max(0, cellW),
                    height: max(0, cellH)
                )
                let path = Path(roundedRect: rect, cornerRadius: 2)
                if bucket.count == 0 {
                    context.fill(path, with: .color(.white.opacity(0.04)))
                } else {
                    let intensity = Double(bucket.count) / Double(maxCount)
                    // Single occupant = cool/safe; collisions warm toward red.
                    let hue = bucket.isCollision ? 0.02 : 0.55
                    context.fill(
                        path,
                        with: .color(Color(hue: hue, saturation: 0.85, brightness: 1.0)
                            .opacity(0.25 + 0.7 * intensity))
                    )
                    if bucket.isCollision {
                        context.stroke(path, with: .color(.white.opacity(0.7)), lineWidth: 1)
                    }
                }
            }
        }
    }
}

#if DEBUG
    #Preview("Collision matrix") {
        CollisionMatrixView(viewModel: CollisionMatrixPreviewData.viewModel())
            .frame(width: 760, height: 720)
    }
#endif
