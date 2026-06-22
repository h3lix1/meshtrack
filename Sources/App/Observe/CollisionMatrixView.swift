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
    /// Last-known positions keyed by `nodeNum`, used for earshot validation in the
    /// click-through panel. Only the colliding nodes need a fix; absent → `.unknown`.
    public private(set) var positions: [Int64: GeoPoint]
    /// LoRa max-range threshold for the earshot check (metres). Configurable per
    /// fleet; defaults to `Earshot.defaultMaxRangeMeters` (~10 km).
    public let maxRangeMeters: Double
    /// The byte the user last selected in the matrix (`0...255`), or `nil`. Drives the
    /// click-through detail panel. Only collisions (2+ nodes) are selectable.
    public var selectedByte: Int?
    @ObservationIgnored private let store: MeshStore?

    /// Store-backed: `load()` reads the node set (and colliding-node positions) from
    /// the store.
    public init(store: MeshStore, maxRangeMeters: Double = Earshot.defaultMaxRangeMeters) {
        self.store = store
        self.maxRangeMeters = maxRangeMeters
        analysis = CollisionMatrix.analyse([])
        positions = [:]
        selectedByte = nil
    }

    /// Memory-only: seeded from a node set (live coordinator / previews / tests).
    /// `load()` is a no-op; drive it with `update(nodes:positions:)`. `positions` is
    /// optional so existing call sites stay source-compatible.
    public init(
        nodes: [CollisionNode] = [],
        positions: [Int64: GeoPoint] = [:],
        maxRangeMeters: Double = Earshot.defaultMaxRangeMeters
    ) {
        store = nil
        self.maxRangeMeters = maxRangeMeters
        analysis = CollisionMatrix.analyse(nodes)
        self.positions = positions
        selectedByte = nil
    }

    /// Build the analysis from the store's current node set, then load the last-known
    /// position of every node that actually collides (a small set). A no-op when the
    /// VM is memory-only.
    public func load() async throws {
        guard let store else { return }
        let nodes = try await store.allNodes().map(Self.collisionNode)
        analysis = CollisionMatrix.analyse(nodes)
        positions = try await Self.loadPositions(for: analysis, from: store)
    }

    /// Re-run the analysis over an in-memory node set (live coordinator / tests).
    /// `positions` is merged in for the earshot check; pass `[:]` to leave them
    /// unknown. Optional so existing call sites stay source-compatible.
    public func update(nodes: [CollisionNode], positions: [Int64: GeoPoint] = [:]) {
        analysis = CollisionMatrix.analyse(nodes)
        self.positions = positions
    }

    /// The earshot verdicts for the currently selected byte's collision bucket, or
    /// `[]` when nothing (collidable) is selected.
    public var selectedEarshotPairs: [EarshotPair] {
        guard let byte = selectedByte,
              analysis.lastByteBuckets.indices.contains(byte)
        else { return [] }
        return Earshot.pairs(
            in: analysis.lastByteBuckets[byte],
            positions: positions,
            maxRangeMeters: maxRangeMeters
        )
    }

    /// The collision bucket for the selected byte, when it is a real collision (2+).
    public var selectedBucket: CollisionBucket? {
        guard let byte = selectedByte,
              analysis.lastByteBuckets.indices.contains(byte)
        else { return nil }
        let bucket = analysis.lastByteBuckets[byte]
        return bucket.isCollision ? bucket : nil
    }

    /// Toggle-select a byte from the matrix. Only collisions are selectable; tapping a
    /// single-occupant or empty cell clears the selection, and tapping the selected
    /// cell again deselects.
    public func select(byte: Int) {
        guard analysis.lastByteBuckets.indices.contains(byte),
              analysis.lastByteBuckets[byte].isCollision
        else {
            selectedByte = nil
            return
        }
        selectedByte = (selectedByte == byte) ? nil : byte
    }

    /// Load the last-known fix for every node that collides on a last byte. Only
    /// colliding buckets matter for earshot, and the set is small, so this issues one
    /// `positionFixes` query per such node and keeps the most recent fix.
    nonisolated static func loadPositions(
        for analysis: CollisionAnalysis,
        from store: MeshStore
    ) async throws -> [Int64: GeoPoint] {
        let collidingNums = analysis.lastByteBuckets
            .filter(\.isCollision)
            .flatMap(\.nodes)
            .map(\.nodeNum)
        var result: [Int64: GeoPoint] = [:]
        for nodeNum in Set(collidingNums) {
            // `positionFixes` is time-ordered ascending; the last is most recent.
            if let fix = try await store.positionFixes(forNode: nodeNum).last {
                result[nodeNum] = GeoPoint(latitude: fix.lat, longitude: fix.lon)
            }
        }
        return result
    }

    nonisolated static func collisionNode(_ record: NodeRecord) -> CollisionNode {
        let hex = NodeID.hex(UInt32(truncatingIfNeeded: record.node_num))
        return CollisionNode(
            nodeNum: record.node_num,
            name: record.short_name ?? record.long_name ?? hex
        )
    }
}

/// The collision section: a header, the 16×16 last-byte heatmap, and the short-id
/// collision list. Self-loads from the store on appear (store-backed VMs only);
/// memory-only VMs are already seeded, so `load()` is a no-op for them.
public struct CollisionMatrixView: View {
    @State private var viewModel: CollisionMatrixViewModel
    @State private var loaded = false

    public init(viewModel: CollisionMatrixViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if viewModel.analysis.nodeCount == 0 {
                emptyState
            } else {
                heatmapCard
                if viewModel.selectedBucket != nil {
                    detailCard
                }
                shortIDCard
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ObserveTheme.background)
        .task {
            // Store-backed VMs fetch their nodes here; memory-only VMs no-op.
            try? await viewModel.load()
            loaded = true
        }
    }

    /// Shown when no nodes have been heard yet — distinguishes empty-because-no-data
    /// from a broken (never-loaded) matrix.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loaded ? "No nodes yet" : "Loading…")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            Text(loaded
                ? "The collision matrix populates as nodes are heard. Nothing to "
                + "compare yet — relay-byte ambiguity needs at least two nodes."
                : "Reading the node set from the store…")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ObserveTheme.card, in: RoundedRectangle(cornerRadius: 12))
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
            CollisionHeatmap(
                buckets: viewModel.analysis.lastByteBuckets,
                selectedByte: viewModel.selectedByte,
                onTap: { viewModel.select(byte: $0) }
            )
            .frame(height: 280)
            Text("Tap an outlined (colliding) cell to inspect the nodes sharing that byte.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(ObserveTheme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    /// The click-through detail: the nodes sharing the selected last byte (name, full
    /// `!aabbccdd` id, short id, relay confidence) plus per-pair earshot verdicts.
    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let bucket = viewModel.selectedBucket {
                HStack(spacing: 8) {
                    Text("BYTE 0x\(bucket.key.uppercased())")
                        .font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                    Text("× \(bucket.count) nodes share it")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.orange)
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(bucket.nodes) { node in
                        CollisionNodeRow(
                            node: node,
                            confidence: viewModel.analysis.relayConfidence(forNodeNum: node.nodeNum)
                        )
                    }
                }
                let pairs = viewModel.selectedEarshotPairs
                if !pairs.isEmpty {
                    Divider().overlay(Color.white.opacity(0.1))
                    Text("EARSHOT — could they be the same hop?")
                        .font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(pairs) { pair in
                            EarshotPairRow(pair: pair)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ObserveTheme.card, in: RoundedRectangle(cornerRadius: 12))
    }

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

/// One node row in the click-through panel: name, full `!aabbccdd` id, 4-hex short
/// id, and the relay-guess confidence (`1 / candidates`).
private struct CollisionNodeRow: View {
    let node: CollisionNode
    let confidence: Double?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(node.name)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 90, alignment: .leading)
            Text(node.hexID)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            Text(node.shortID)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.orange)
            Spacer()
            if let confidence {
                Text("conf \(String(format: "%.2f", confidence))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(confidence < 1.0 ? .orange : .secondary)
            }
        }
    }
}

/// One earshot pair row: the two short ids, the great-circle distance, and the
/// in-range / out-of-range / unknown verdict.
private struct EarshotPairRow: View {
    let pair: EarshotPair

    var body: some View {
        HStack(spacing: 8) {
            Text("\(pair.a.shortID) ↔ \(pair.b.shortID)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
            Spacer()
            Text(verdict)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    private var verdict: String {
        switch pair.range {
        case let .inRange(meters): "\(Self.km(meters)) — in range"
        case let .outOfRange(meters): "\(Self.km(meters)) — out of range"
        case .unknown: "position unknown"
        }
    }

    private var color: Color {
        switch pair.range {
        case .inRange: .green
        case .outOfRange: .orange
        case .unknown: .secondary
        }
    }

    /// Metres → a compact "2.3 km" / "640 m" label.
    private static func km(_ meters: Double) -> String {
        meters >= 1000
            ? String(format: "%.1f km", meters / 1000)
            : String(format: "%.0f m", meters)
    }
}

/// The 16×16 last-byte heatmap, rendered as a bespoke `Grid` of shape-backed cells
/// (NOT `Canvas`/stock controls) so it both hit-tests for the click-through and stays
/// faithful in headless `ImageRenderer` snapshots. Cell intensity tracks the number
/// of nodes sharing that byte; occupied cells show the byte value (and count when
/// colliding); a cell with 2+ nodes (an ambiguous relay byte) is outlined, and the
/// selected cell is highlighted. Tapping a colliding cell calls `onTap`.
struct CollisionHeatmap: View {
    let buckets: [CollisionBucket]
    var selectedByte: Int?
    var onTap: ((Int) -> Void)?

    private static let cols = 16
    private static let rows = 16

    private var maxCount: Int {
        max(buckets.map(\.count).max() ?? 0, 1)
    }

    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach(0 ..< Self.rows, id: \.self) { row in
                GridRow {
                    ForEach(0 ..< Self.cols, id: \.self) { col in
                        let value = row * Self.cols + col
                        CollisionCell(
                            bucket: bucketFor(value),
                            value: value,
                            maxCount: maxCount,
                            isSelected: selectedByte == value
                        )
                        .onTapGesture { onTap?(value) }
                    }
                }
            }
        }
    }

    private func bucketFor(_ value: Int) -> CollisionBucket? {
        buckets.indices.contains(value) ? buckets[value] : nil
    }
}

/// A single heatmap cell: a rounded rect coloured by occupancy, with the byte value
/// (and node count when colliding) drawn legibly on top. Bespoke shapes + `Text` keep
/// it crisp headless.
private struct CollisionCell: View {
    let bucket: CollisionBucket?
    let value: Int
    let maxCount: Int
    let isSelected: Bool

    private var count: Int {
        bucket?.count ?? 0
    }

    private var isCollision: Bool {
        count > 1
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(strokeColor, lineWidth: strokeWidth)
            )
            .overlay(label)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
    }

    /// Byte value in hex, with the node count beneath when 2+ share it. Empty cells
    /// stay blank so the grid reads as a heatmap, not a wall of zeros.
    @ViewBuilder private var label: some View {
        if count > 0 {
            VStack(spacing: 0) {
                Text(String(format: "%02x", value))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                if isCollision {
                    Text("×\(count)")
                        .font(.system(size: 7, weight: .heavy, design: .monospaced))
                }
            }
            .foregroundStyle(.white)
            .minimumScaleFactor(0.5)
        }
    }

    private var fillColor: Color {
        guard count > 0 else { return .white.opacity(0.04) }
        let intensity = Double(count) / Double(maxCount)
        // Single occupant = cool/safe; collisions warm toward red.
        let hue = isCollision ? 0.02 : 0.55
        return Color(hue: hue, saturation: 0.85, brightness: 1.0)
            .opacity(0.25 + 0.7 * intensity)
    }

    private var strokeColor: Color {
        if isSelected { return .white }
        return isCollision ? .white.opacity(0.7) : .clear
    }

    private var strokeWidth: CGFloat {
        isSelected ? 2 : (isCollision ? 1 : 0)
    }
}

#if DEBUG
    #Preview("Collision matrix") {
        CollisionMatrixView(viewModel: CollisionMatrixPreviewData.viewModel())
            .frame(width: 760, height: 720)
    }

    #Preview("Collision matrix — byte selected") {
        CollisionMatrixView(viewModel: CollisionMatrixPreviewData.selectedViewModel())
            .frame(width: 760, height: 860)
    }
#endif
