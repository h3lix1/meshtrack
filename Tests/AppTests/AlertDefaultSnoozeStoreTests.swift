@testable import App
import Persistence
import Testing

@Suite("AlertDefaultSnoozeStore — real MeshStore-backed default-snooze persistence")
struct AlertDefaultSnoozeStoreTests {
    /// A fresh real (GRDB) MeshStore over an in-memory connection — the SAME
    /// persistence path the production `MeshStoreAlertRuleStore` adapter uses, not
    /// the in-memory fake that masked Finding 10.
    private func makeStore() throws -> MeshStore {
        try MeshStore(DatabaseConnection.inMemory())
    }

    @Test
    func `an unset default snooze falls back to 3600`() async throws {
        let store = try makeStore()
        let loaded = try await AlertDefaultSnoozeStore.load(from: store)
        #expect(loaded == AlertDefaultSnoozeStore.fallbackSeconds)
        #expect(loaded == 3600)
    }

    @Test
    func `a saved default snooze round-trips through the real store`() async throws {
        // The exact failure mode of Finding 10: save an operator edit, then load it
        // back from the real app_config-backed store (a fresh read, as on relaunch).
        let store = try makeStore()
        try await AlertDefaultSnoozeStore.save(900, to: store)
        let loaded = try await AlertDefaultSnoozeStore.load(from: store)
        #expect(loaded == 900)
    }

    @Test
    func `the latest saved value wins`() async throws {
        let store = try makeStore()
        try await AlertDefaultSnoozeStore.save(900, to: store)
        try await AlertDefaultSnoozeStore.save(1800, to: store)
        #expect(try await AlertDefaultSnoozeStore.load(from: store) == 1800)
    }

    @Test
    func `the snooze key does not collide with the channel registry`() async throws {
        // Both live in app_config; writing one must not clobber the other.
        let store = try makeStore()
        try await store.setAppConfigValue("[]", forKey: "channel_registry")
        try await AlertDefaultSnoozeStore.save(1200, to: store)
        #expect(try await AlertDefaultSnoozeStore.load(from: store) == 1200)
        #expect(try await store.appConfigValue(forKey: "channel_registry") == "[]")
    }
}
