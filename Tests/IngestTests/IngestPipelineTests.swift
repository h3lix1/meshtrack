import Domain
import Foundation
@testable import Ingest
import Persistence
import Testing
import Transport

@Suite("Ingest pipeline (replay → persist)")
struct IngestPipelineTests {
    /// Repo root, located from this source file so it is CWD-independent.
    private func repoRoot() -> URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // IngestTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // <root>
    }

    @Test
    func `a replayed corpus produces persisted nodes (Phase 0 done-condition)`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let adapter = try ReplayAdapter(directory: repoRoot()
            .appendingPathComponent("Corpus/synthetic-basic"))

        let summary = try await IngestPipeline(store: store).run(adapter)
        #expect(summary.framesProcessed == 3)
        #expect(summary.framesAttributed == 3)

        // synthetic-basic carries two distinct gateway nodes: !a1b2c3d4 (x2), !e5f6a7b8.
        let nodeA = try await store.fetchNode(nodeNum: 0xA1B2_C3D4)
        let nodeB = try await store.fetchNode(nodeNum: 0xE5F6_A7B8)
        #expect(nodeA != nil)
        #expect(nodeB != nil)
        // !a1b2c3d4 was heard twice: first_seen at the first frame, last_heard at the second.
        #expect(nodeA?.first_seen_at == 1_718_712_000_000_000_000)
        #expect(nodeA?.last_heard_at == 1_718_712_005_000_000_000)
    }

    @Test
    func `frames without a node identity are skipped, never fatal`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let adapter = try ReplayAdapter(
            directory: repoRoot().appendingPathComponent("Corpus/synthetic-mixed-transport")
        )
        let summary = try await IngestPipeline(store: store).run(adapter)
        // 3 frames; only the MQTT frame carries a gateway id (serial/ble do not).
        #expect(summary.framesProcessed == 3)
        #expect(summary.framesAttributed == 1)
        #expect(try await store.fetchNode(nodeNum: 0xC0FF_EE00) != nil)
    }

    @Test
    func `hex-id parsing tolerates the ! prefix and rejects junk`() {
        #expect(IngestPipeline.nodeNum(fromHexID: "!a1b2c3d4") == 0xA1B2_C3D4)
        #expect(IngestPipeline.nodeNum(fromHexID: "deadbeef") == 0xDEAD_BEEF)
        #expect(IngestPipeline.nodeNum(fromHexID: nil) == nil)
        #expect(IngestPipeline.nodeNum(fromHexID: "!") == nil)
        #expect(IngestPipeline.nodeNum(fromHexID: "nothex") == nil)
    }
}
