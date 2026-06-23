@testable import App
import Domain
import Persistence
import Testing

@Suite("Collision matrix analysis")
struct CollisionMatrixTests {
    @Test
    func `last byte is the low 8 bits, short id the low 16`() {
        let node = CollisionNode(nodeNum: 0xA1B2_C3D4, name: "x")
        #expect(node.lastByte == 0xD4)
        #expect(node.shortID == "c3d4")
        #expect(node.hexID == "!a1b2c3d4")
    }

    @Test
    func `nodes sharing a last byte land in one bucket`() {
        let analysis = CollisionMatrix.analyse([
            CollisionNode(nodeNum: 0x1111_11D4, name: "a"),
            CollisionNode(nodeNum: 0x2222_22D4, name: "b"),
            CollisionNode(nodeNum: 0x3333_3301, name: "c")
        ])
        let d4 = analysis.lastByteBuckets[0xD4]
        #expect(d4.count == 2)
        #expect(d4.isCollision)
        #expect(d4.nodes.map(\.name) == ["a", "b"])

        let one = analysis.lastByteBuckets[0x01]
        #expect(one.count == 1)
        #expect(!one.isCollision)
    }

    @Test
    func `the grid is always a full 256 buckets indexed by byte value`() {
        let analysis = CollisionMatrix.analyse([CollisionNode(nodeNum: 0x07, name: "a")])
        #expect(analysis.lastByteBuckets.count == 256)
        #expect(analysis.lastByteBuckets[7].count == 1)
        #expect(analysis.lastByteBuckets[7].byteValue == 7)
        // Every other byte is an empty bucket.
        #expect(analysis.lastByteBuckets[8].nodes.isEmpty)
    }

    @Test
    func `short-id collisions list only buckets with 2+ nodes, worst first`() {
        let analysis = CollisionMatrix.analyse([
            // Three share short id c3d4.
            CollisionNode(nodeNum: 0x1111_C3D4, name: "a"),
            CollisionNode(nodeNum: 0x2222_C3D4, name: "b"),
            CollisionNode(nodeNum: 0x3333_C3D4, name: "c"),
            // Two share short id 0001.
            CollisionNode(nodeNum: 0xAAAA_0001, name: "d"),
            CollisionNode(nodeNum: 0xBBBB_0001, name: "e"),
            // Unique short id — excluded.
            CollisionNode(nodeNum: 0xCCCC_BEEF, name: "f")
        ])
        #expect(analysis.shortIDCollisions.count == 2)
        // Worst (count 3) first.
        #expect(analysis.shortIDCollisions[0].key == "c3d4")
        #expect(analysis.shortIDCollisions[0].count == 3)
        #expect(analysis.shortIDCollisions[1].key == "0001")
    }

    @Test
    func `max collision and ambiguous-byte counts summarise the worst case`() {
        let analysis = CollisionMatrix.analyse([
            CollisionNode(nodeNum: 0x1111_11D4, name: "a"),
            CollisionNode(nodeNum: 0x2222_22D4, name: "b"),
            CollisionNode(nodeNum: 0x3333_33D4, name: "c"),
            CollisionNode(nodeNum: 0x4444_44AA, name: "d"),
            CollisionNode(nodeNum: 0x5555_55AA, name: "e")
        ])
        #expect(analysis.maxLastByteCollision == 3) // three d4s
        #expect(analysis.collidingByteCount == 2) // d4 and aa
        #expect(analysis.nodeCount == 5)
    }

    @Test
    func `relay confidence is one over the candidates sharing the byte`() {
        let analysis = CollisionMatrix.analyse([
            CollisionNode(nodeNum: 0x1111_11D4, name: "a"),
            CollisionNode(nodeNum: 0x2222_22D4, name: "b"),
            CollisionNode(nodeNum: 0x3333_3301, name: "c")
        ])
        // Two share d4 → 0.5 confidence each.
        #expect(analysis.relayConfidence(forNodeNum: 0x1111_11D4) == 0.5)
        // Unique last byte → fully confident.
        #expect(analysis.relayConfidence(forNodeNum: 0x3333_3301) == 1.0)
        // Not in the set → nil.
        #expect(analysis.relayConfidence(forNodeNum: 0xDEAD_BEEF) == nil)
    }

    @Test
    func `empty fleet yields an empty grid summary`() {
        let analysis = CollisionMatrix.analyse([])
        #expect(analysis.nodeCount == 0)
        #expect(analysis.maxLastByteCollision == 0)
        #expect(analysis.collidingByteCount == 0)
        #expect(analysis.shortIDCollisions.isEmpty)
        #expect(analysis.lastByteBuckets.count == 256)
    }

    @Test
    @MainActor
    func `view model loads collisions from the store`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        try await store.markHeard(nodeNum: 0x1111_11D4, at: Instant(nanosecondsSinceEpoch: 1))
        try await store.markHeard(nodeNum: 0x2222_22D4, at: Instant(nanosecondsSinceEpoch: 2))
        try await store.markHeard(nodeNum: 0x3333_3301, at: Instant(nanosecondsSinceEpoch: 3))

        let viewModel = CollisionMatrixViewModel(store: store)
        try await viewModel.load()
        #expect(viewModel.analysis.nodeCount == 3)
        #expect(viewModel.analysis.maxLastByteCollision == 2)
        #expect(viewModel.analysis.relayConfidence(forNodeNum: 0x1111_11D4) == 0.5)
    }

    @Test
    @MainActor
    func `store-backed load turns an empty matrix into a colliding one`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        // Two nodes share last byte 0xd4 (ambiguous relay byte); one is unique.
        try await store.markHeard(nodeNum: 0xA1B2_C3D4, at: Instant(nanosecondsSinceEpoch: 1))
        try await store.markHeard(nodeNum: 0x9988_77D4, at: Instant(nanosecondsSinceEpoch: 2))
        try await store.markHeard(nodeNum: 0x3333_3301, at: Instant(nanosecondsSinceEpoch: 3))

        let viewModel = CollisionMatrixViewModel(store: store)
        // Before load() the matrix is the empty seed (this is the bug the view's
        // .task fixes — without a load the matrix stays here).
        #expect(viewModel.analysis.nodeCount == 0)
        #expect(viewModel.analysis.maxLastByteCollision == 0)

        try await viewModel.load()

        // After load() the analysis is non-empty and surfaces the d4 collision.
        #expect(viewModel.analysis.nodeCount == 3)
        #expect(viewModel.analysis.maxLastByteCollision == 2)
        #expect(viewModel.analysis.collidingByteCount == 1)
        #expect(viewModel.analysis.lastByteBuckets[0xD4].count == 2)

        // A node sharing the byte is ambiguous → confidence below 1; the unique
        // node is fully confident.
        let colliding = try #require(viewModel.analysis.relayConfidence(forNodeNum: 0xA1B2_C3D4))
        #expect(colliding < 1.0)
        #expect(colliding == 0.5)
        #expect(viewModel.analysis.relayConfidence(forNodeNum: 0x3333_3301) == 1.0)
    }

    @Test
    @MainActor
    func `memory-only view model updates from an in-memory set`() {
        let viewModel = CollisionMatrixViewModel()
        #expect(viewModel.analysis.nodeCount == 0)
        viewModel.update(nodes: CollisionMatrixPreviewData.nodes())
        #expect(viewModel.analysis.nodeCount == 8)
        // The preview set has four nodes ending in d4.
        #expect(viewModel.analysis.lastByteBuckets[0xD4].count == 4)
    }
}

@Suite("Earshot range analysis")
struct EarshotTests {
    // Two points ~1.3 km apart in central London.
    private let london = GeoPoint(latitude: 51.5074, longitude: -0.1278)
    private let londonNorth = GeoPoint(latitude: 51.5194, longitude: -0.1270)
    private let edinburgh = GeoPoint(latitude: 55.9533, longitude: -3.1883)

    @Test
    func `nearby nodes are in range`() {
        let range = Earshot.classify(from: london, to: londonNorth)
        guard case let .inRange(meters) = range else {
            Issue.record("expected inRange, got \(range)")
            return
        }
        #expect(meters > 1000 && meters < 2000)
    }

    @Test
    func `distant nodes are out of range`() {
        let range = Earshot.classify(from: london, to: edinburgh)
        guard case let .outOfRange(meters) = range else {
            Issue.record("expected outOfRange, got \(range)")
            return
        }
        // London → Edinburgh is ~530 km.
        #expect(meters > 500_000)
    }

    @Test
    func `a missing position yields unknown`() {
        #expect(Earshot.classify(from: london, to: nil) == .unknown)
        #expect(Earshot.classify(from: nil, to: edinburgh) == .unknown)
        #expect(Earshot.classify(from: nil, to: nil) == .unknown)
    }

    @Test
    func `the threshold is the in-range boundary and is configurable`() {
        // ~1.3 km apart: in range at 10 km default, out of range at 1 km.
        if case .inRange = Earshot.classify(from: london, to: londonNorth) {} else {
            Issue.record("expected in range at default threshold")
        }
        if case .outOfRange = Earshot.classify(from: london, to: londonNorth, maxRangeMeters: 1000) {} else {
            Issue.record("expected out of range at a 1 km threshold")
        }
    }

    @Test
    func `default threshold is ten kilometres`() {
        #expect(Earshot.defaultMaxRangeMeters == 10000)
    }

    @Test
    func `pairs enumerates every distinct pair in a colliding bucket`() {
        let analysis = CollisionMatrix.analyse([
            CollisionNode(nodeNum: 0x1111_11D4, name: "a"),
            CollisionNode(nodeNum: 0x2222_22D4, name: "b"),
            CollisionNode(nodeNum: 0x3333_33D4, name: "c")
        ])
        let pairs = Earshot.pairs(in: analysis.lastByteBuckets[0xD4], positions: [:])
        // 3 nodes → C(3,2) = 3 pairs, all unknown (no positions supplied).
        #expect(pairs.count == 3)
        #expect(pairs.allSatisfy { $0.range == .unknown })
        // Pairs respect ascending nodeNum order within each pair.
        #expect(pairs.allSatisfy { $0.nodeA.nodeNum < $0.nodeB.nodeNum })
    }

    @Test
    func `pairs classifies each pair from its positions`() throws {
        let a = CollisionNode(nodeNum: 0x1111_11D4, name: "a")
        let b = CollisionNode(nodeNum: 0x2222_22D4, name: "b")
        let c = CollisionNode(nodeNum: 0x3333_33D4, name: "c")
        let analysis = CollisionMatrix.analyse([a, b, c])
        let positions: [Int64: GeoPoint] = [
            a.nodeNum: london,
            b.nodeNum: londonNorth,
            c.nodeNum: edinburgh
        ]
        let pairs = Earshot.pairs(in: analysis.lastByteBuckets[0xD4], positions: positions)
        // a↔b nearby = in range; a↔c and b↔c far = out of range.
        let ab = try #require(pairs.first { $0.nodeA.nodeNum == a.nodeNum && $0.nodeB.nodeNum == b.nodeNum })
        let ac = try #require(pairs.first { $0.nodeA.nodeNum == a.nodeNum && $0.nodeB.nodeNum == c.nodeNum })
        if case .inRange = ab.range {} else { Issue.record("a↔b should be in range") }
        if case .outOfRange = ac.range {} else { Issue.record("a↔c should be out of range") }
    }

    @Test
    func `a non-colliding bucket has no pairs`() {
        let analysis = CollisionMatrix.analyse([CollisionNode(nodeNum: 0x07, name: "a")])
        #expect(Earshot.pairs(in: analysis.lastByteBuckets[0x07], positions: [:]).isEmpty)
        #expect(Earshot.pairs(in: analysis.lastByteBuckets[0x08], positions: [:]).isEmpty)
    }
}

@Suite("Collision matrix selection + positions")
@MainActor
struct CollisionMatrixSelectionTests {
    @Test
    func `selecting a colliding byte exposes its bucket and earshot pairs`() throws {
        let viewModel = CollisionMatrixPreviewData.selectedViewModel()
        let bucket = try #require(viewModel.selectedBucket)
        #expect(bucket.byteValue == 0xD4)
        #expect(bucket.count == 4)
        // The preview seeds in-range, out-of-range, and unknown verdicts.
        let pairs = viewModel.selectedEarshotPairs
        #expect(pairs.contains { if case .inRange = $0.range { true } else { false } })
        #expect(pairs.contains { if case .outOfRange = $0.range { true } else { false } })
        #expect(pairs.contains { $0.range == .unknown })
    }

    @Test
    func `tapping a single-occupant or empty cell clears the selection`() {
        let viewModel = CollisionMatrixPreviewData.selectedViewModel()
        #expect(viewModel.selectedByte == 0xD4)
        // 0x7f has a single node (MOBILE) → not selectable.
        viewModel.select(byte: 0x7F)
        #expect(viewModel.selectedByte == nil)
        #expect(viewModel.selectedBucket == nil)
    }

    @Test
    func `tapping the selected byte again deselects it`() {
        let viewModel = CollisionMatrixPreviewData.selectedViewModel()
        viewModel.select(byte: 0xD4)
        #expect(viewModel.selectedByte == nil)
    }

    @Test
    func `store-backed load fetches positions for colliding nodes only`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        // Two nodes share 0xd4; one has a fix, one does not. A unique node is ignored.
        try await store.markHeard(nodeNum: 0xA1B2_C3D4, at: Instant(nanosecondsSinceEpoch: 1))
        try await store.markHeard(nodeNum: 0x9988_77D4, at: Instant(nanosecondsSinceEpoch: 2))
        try await store.markHeard(nodeNum: 0x3333_3301, at: Instant(nanosecondsSinceEpoch: 3))
        _ = try await store.appendPositionFix(
            PositionFixRecord(node_num: 0xA1B2_C3D4, t: 10, lat: 51.5, lon: -0.12)
        )

        let viewModel = CollisionMatrixViewModel(store: store)
        try await viewModel.load()
        // Only the colliding node with a fix is present.
        #expect(viewModel.positions[0xA1B2_C3D4] != nil)
        #expect(viewModel.positions[0x9988_77D4] == nil)
        #expect(viewModel.positions[0x3333_3301] == nil)

        viewModel.select(byte: 0xD4)
        let pairs = viewModel.selectedEarshotPairs
        // One node lacks a fix → the single pair is unknown.
        #expect(pairs.count == 1)
        #expect(pairs.first?.range == .unknown)
    }
}
