// CollisionMatrixView — the bespoke 16×16 last-byte heatmap + short-id collision
// list (G10). Reveals which relay bytes are ambiguous (shared by several nodes),
// directly informing the map's relay-confidence hint. The heatmap is a bespoke
// `Grid` of shape-backed cells (NOT stock controls) so it hit-tests for the
// click-through and renders faithfully headless; backed by `CollisionMatrixViewModel`
// over the store. The cell/row subviews live in `CollisionMatrixComponents.swift`.

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
