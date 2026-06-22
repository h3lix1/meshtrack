import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@Suite("Migration v6 — bounded windowed extraction dedup (Finding 5)")
struct MigrationV6Tests {
    private func at(_ seconds: Double) -> Instant {
        Instant.epoch.adding(seconds: seconds)
    }

    @Test
    func `the same identity re-offered within the window is rejected (durable dedup)`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        // First sighting at t=0 → admitted.
        let first = try await store.admitExtraction(
            packetID: 42, fromNum: 7, at: at(0), windowSeconds: 600
        )
        #expect(first)
        // Re-offered 599s later (still inside the 600s window) → rejected.
        let withinWindow = try await store.admitExtraction(
            packetID: 42, fromNum: 7, at: at(599), windowSeconds: 600
        )
        #expect(!withinWindow)
    }

    @Test
    func `the same identity after the window records a NEW admission (Finding 5)`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        #expect(try await store.admitExtraction(packetID: 42, fromNum: 7, at: at(0), windowSeconds: 600))
        // 601s later — the window has elapsed — the SAME key is admitted again, so a
        // legitimate packet-id reuse is no longer dropped forever (the v5 bug).
        let afterWindow = try await store.admitExtraction(
            packetID: 42, fromNum: 7, at: at(601), windowSeconds: 600
        )
        #expect(afterWindow)
    }

    @Test
    func `a repeat sighting slides the window forward`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        #expect(try await store.admitExtraction(packetID: 1, fromNum: 1, at: at(0), windowSeconds: 600))
        // Seen again at 500s (within window) → rejected, but slides last-seen to 500.
        #expect(!(try await store.admitExtraction(packetID: 1, fromNum: 1, at: at(500), windowSeconds: 600)))
        // 900s is 400s after the slid 500 — still within the window → rejected.
        #expect(!(try await store.admitExtraction(packetID: 1, fromNum: 1, at: at(900), windowSeconds: 600)))
    }

    @Test
    func `distinct identities are tracked independently`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        #expect(try await store.admitExtraction(packetID: 1, fromNum: 7, at: at(0), windowSeconds: 600))
        // Different packet_id, same node → independent key → admitted.
        #expect(try await store.admitExtraction(packetID: 2, fromNum: 7, at: at(0), windowSeconds: 600))
        // Same packet_id, different node → independent key → admitted.
        #expect(try await store.admitExtraction(packetID: 1, fromNum: 8, at: at(0), windowSeconds: 600))
    }

    @Test
    func `the ledger is pruned so it stays bounded`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        // Seed an old key at t=0.
        #expect(try await store.admitExtraction(packetID: 1, fromNum: 1, at: at(0), windowSeconds: 600))
        // A far-future admission prunes everything older than the window.
        #expect(try await store.admitExtraction(packetID: 2, fromNum: 1, at: at(10_000), windowSeconds: 600))
        let ledgerSize = try await store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dedup_seen") ?? -1
        }
        // The expired t=0 key was pruned; only the recent one remains.
        #expect(ledgerSize == 1)
    }
}
