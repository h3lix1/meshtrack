import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@Suite("MeshStore: ConfigGateway (Phase 8)")
struct ConfigGatewayTests {
    private func makeStore() throws -> MeshStore {
        try MeshStore(DatabaseConnection.inMemory())
    }

    // MARK: - Broker config

    @Test
    func `loadBrokerConfig returns nil when none has been saved`() async throws {
        let store = try makeStore()
        let loaded = try await store.loadBrokerConfig()
        #expect(loaded == nil)
    }

    @Test
    func `broker config round-trips through the store`() async throws {
        let store = try makeStore()
        let config = BrokerConfig(
            host: "mqtt.meshtastic.org",
            port: 8883,
            username: "clive",
            useTLS: true,
            allowUntrustedCert: false,
            topics: ["msh/US/bayarea/2/e/#", "msh/US/2/e/#"],
            clientID: "meshtrack-mac"
        )
        try await store.saveBrokerConfig(config)
        let loaded = try await store.loadBrokerConfig()
        #expect(loaded == config)
    }

    @Test
    func `broker config saves no plaintext secret — only the non-secret fields`() async throws {
        // SPEC §2.5: the DB never stores plaintext secrets. The password is not
        // part of BrokerConfig, so the persisted JSON must not contain it.
        let store = try makeStore()
        try await store.saveBrokerConfig(BrokerConfig(host: "h", username: "u"))
        let raw = try await store.writer.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM \(Table.appConfig) WHERE key = 'broker'"
            )
        }
        let json = raw ?? ""
        #expect(json.contains("\"host\""))
        #expect(!json.lowercased().contains("password"))
    }

    @Test
    func `saving broker config twice overwrites in place (single row)`() async throws {
        let store = try makeStore()
        try await store.saveBrokerConfig(BrokerConfig(host: "first.example", port: 1883))
        try await store.saveBrokerConfig(BrokerConfig(host: "second.example", port: 8883))

        let loaded = try await store.loadBrokerConfig()
        #expect(loaded?.host == "second.example")
        #expect(loaded?.port == 8883)

        // Overwrite-in-place: exactly one broker row exists.
        let count = try await store.writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(Table.appConfig) WHERE key = 'broker'"
            )
        }
        #expect(count == 1)
    }

    // MARK: - App settings

    @Test
    func `loadAppSettings returns the defaults when none have been saved`() async throws {
        let store = try makeStore()
        let loaded = try await store.loadAppSettings()
        #expect(loaded == AppSettings.default)
    }

    @Test
    func `app settings round-trip through the store`() async throws {
        let store = try makeStore()
        let settings = AppSettings(
            refreshIntervalSeconds: 10,
            themeID: "midnight",
            useMetricUnits: false,
            telemetryRetentionDays: 90,
            notificationsEnabled: false,
            startAtLogin: true,
            autoConnect: false
        )
        try await store.saveAppSettings(settings)
        let loaded = try await store.loadAppSettings()
        #expect(loaded == settings)
        // A non-default value really persisted (not silently the default).
        #expect(loaded != AppSettings.default)
    }

    @Test
    func `saving app settings twice overwrites in place (single row)`() async throws {
        let store = try makeStore()
        try await store.saveAppSettings(AppSettings(refreshIntervalSeconds: 5))
        try await store.saveAppSettings(AppSettings(refreshIntervalSeconds: 30))

        let loaded = try await store.loadAppSettings()
        #expect(loaded.refreshIntervalSeconds == 30)

        let count = try await store.writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(Table.appConfig) WHERE key = 'app_settings'"
            )
        }
        #expect(count == 1)
    }

    // MARK: - Independence

    @Test
    func `broker and app settings persist under independent keys`() async throws {
        let store = try makeStore()
        try await store.saveBrokerConfig(BrokerConfig(host: "broker.example"))
        try await store.saveAppSettings(AppSettings(startAtLogin: true))

        #expect(try await store.loadBrokerConfig()?.host == "broker.example")
        #expect(try await store.loadAppSettings().startAtLogin == true)
    }

    // MARK: - Port conformance

    @Test
    func `MeshStore is usable through the ConfigGateway port`() async throws {
        let gateway: any ConfigGateway = try makeStore()
        try await gateway.saveBrokerConfig(BrokerConfig(host: "via.port"))
        #expect(try await gateway.loadBrokerConfig()?.host == "via.port")
        #expect(try await gateway.loadAppSettings() == AppSettings.default)
    }
}
