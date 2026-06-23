@testable import Persistence
import Testing

@Suite("MeshStore: app_config key-value (Phase 8)")
struct AppConfigKVTests {
    private func makeStore() throws -> MeshStore {
        try MeshStore(DatabaseConnection.inMemory())
    }

    @Test
    func `unset key returns nil`() async throws {
        let store = try makeStore()
        #expect(try await store.appConfigValue(forKey: "channel_registry") == nil)
    }

    @Test
    func `value round-trips and overwrites in place`() async throws {
        let store = try makeStore()
        try await store.setAppConfigValue("[]", forKey: "channel_registry")
        #expect(try await store.appConfigValue(forKey: "channel_registry") == "[]")
        try await store.setAppConfigValue("[{\"name\":\"a\"}]", forKey: "channel_registry")
        #expect(try await store.appConfigValue(forKey: "channel_registry") == "[{\"name\":\"a\"}]")
    }

    @Test
    func `nil value deletes the row`() async throws {
        let store = try makeStore()
        try await store.setAppConfigValue("x", forKey: "k")
        try await store.setAppConfigValue(nil, forKey: "k")
        #expect(try await store.appConfigValue(forKey: "k") == nil)
    }

    @Test
    func `distinct keys are independent (does not collide with broker/app_settings)`() async throws {
        let store = try makeStore()
        try await store.setAppConfigValue("registry", forKey: "channel_registry")
        // The typed ConfigGateway keys remain untouched.
        #expect(try await store.loadBrokerConfig() == nil)
        #expect(try await store.appConfigValue(forKey: "channel_registry") == "registry")
    }
}
