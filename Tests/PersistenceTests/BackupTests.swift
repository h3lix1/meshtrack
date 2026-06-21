import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@Suite("Database export / backup (SPEC §6)")
struct BackupTests {
    @Test
    func `a backup is a consistent copy that reopens with the data intact`() async throws {
        let source = try MeshStore(DatabaseConnection.inMemory())
        try await source.upsertNode(NodeRecord(
            node_num: 7,
            short_name: "BASE",
            first_seen_at: 1,
            last_heard_at: 2
        ))
        try await source.appendTelemetry(TelemetryRecord(
            node_num: 7,
            t: 10,
            kind: .device,
            key: "battery_pct",
            value: 80
        ))

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await source.backup(toPath: path)

        let restored = try MeshStore(DatabaseQueue(path: path))
        #expect(try await restored.fetchNode(nodeNum: 7)?.short_name == "BASE")
        #expect(try await restored.telemetry(forNode: 7).count == 1)
    }
}
