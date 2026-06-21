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
