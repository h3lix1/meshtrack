// `ConfigGateway` adapter on `MeshStore` (Phase 8, SPEC §2.5/§10).
//
// Non-secret app configuration moves out of environment variables into the
// shared GRDB store: `BrokerConfig` and `AppSettings` are `Codable`, so each is
// JSON-encoded into one `app_config` row under a stable key. Secrets never flow
// through here — the broker password lives in the Keychain via `CredentialStore`.
//
// JSON (rather than a wide typed table) keeps the schema stable as the Domain
// config structs evolve: adding a field is a Domain-only change, no migration.

import Domain
import Foundation
import GRDB

/// `app_config` — one JSON-valued row per config key (schema v4). Used only by
/// the `ConfigGateway` methods; not part of the public record surface.
struct AppConfigRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = Table.appConfig
    var key: String
    var value: String
}

public extension MeshStore {
    /// Stable `app_config` keys. Centralised so a typo can only happen once.
    private enum ConfigKey {
        static let broker = "broker"
        static let appSettings = "app_settings"
    }

    // MARK: - Broker config

    /// The saved broker config, or `nil` if none has been configured yet.
    func loadBrokerConfig() async throws -> BrokerConfig? {
        try await load(BrokerConfig.self, forKey: ConfigKey.broker)
    }

    /// Persist the broker config, overwriting any existing row in place.
    func saveBrokerConfig(_ config: BrokerConfig) async throws {
        try await save(config, forKey: ConfigKey.broker)
    }

    // MARK: - App settings

    /// The saved app settings, or `AppSettings.default` if none have been saved.
    func loadAppSettings() async throws -> AppSettings {
        try await load(AppSettings.self, forKey: ConfigKey.appSettings) ?? .default
    }

    /// Persist the app settings, overwriting any existing row in place.
    func saveAppSettings(_ settings: AppSettings) async throws {
        try await save(settings, forKey: ConfigKey.appSettings)
    }

    // MARK: - Codable <-> app_config row

    /// Decode the JSON value stored under `key`, or `nil` when absent.
    private func load<T: Decodable>(_ type: T.Type, forKey key: String) async throws -> T? {
        let json = try await writer.read { db in
            try AppConfigRecord.fetchOne(db, key: key)?.value
        }
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// JSON-encode `value` and upsert it under `key` (overwrite in place).
    private func save(_ value: some Encodable, forKey key: String) async throws {
        let data = try JSONEncoder().encode(value)
        // The JSON is well-formed UTF-8 by construction; fall back to an empty
        // object rather than force-unwrapping.
        let json = String(data: data, encoding: .utf8) ?? "{}"
        try await writer.write { db in
            try AppConfigRecord(key: key, value: json).save(db)
        }
    }
}

/// `MeshStore` is the production `ConfigGateway` (SPEC §2.5/§10). The Settings UI
/// codes against the `Domain.ConfigGateway` port; the lead wires `MeshStore` in
/// at the composition root.
extension MeshStore: ConfigGateway {}
